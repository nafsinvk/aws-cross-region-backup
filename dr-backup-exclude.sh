#!/bin/bash
###############################################################################
# DR Backup Exclude Script
# Updates AWS Backup selections to exclude instances tagged backup-exclude=true
# Usage: ./dr-backup-exclude.sh [--region REGION]
# Requires: AWS CLI v2, jq, appropriate IAM permissions
###############################################################################

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
REGION="${AWS_DEFAULT_REGION:-me-south-1}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        *) echo "Usage: $0 [--region REGION]"; exit 1 ;;
    esac
done

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

confirm() {
    local prompt="$1"
    while true; do
        echo -en "${YELLOW}${prompt} (y/n): ${NC}"
        read -r answer
        case "$answer" in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO])     return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

separator() {
    echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─── Detect Account ──────────────────────────────────────────────────────────
separator
echo -e "${BOLD}AWS BACKUP EXCLUSION SCRIPT${NC}"
echo -e "Adds exclusion condition for tag 'backup-exclude=true' to backup selections"
separator

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) || {
    error "Failed to get AWS account info. Check your credentials."
    exit 1
}
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "N/A")

echo -e "  Account:  ${BOLD}${ACCOUNT_ID}${NC} (${ACCOUNT_ALIAS})"
echo -e "  Region:   ${BOLD}${REGION}${NC}"
echo -e "  Date:     $(date '+%Y-%m-%d %H:%M:%S')"
separator

# ─── Find tagged instances ──────────────────────────────────────────────────
echo ""
info "Finding instances tagged with backup-exclude=true..."

EXCLUDED_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:backup-exclude,Values=true" \
    --query 'Reservations[].Instances[].[InstanceId, State.Name, (Tags[?Key==`Name`].Value)[0]]' \
    --output text --region "$REGION" 2>/dev/null || echo "")

if [[ -z "$EXCLUDED_INSTANCES" ]]; then
    warn "No instances found with tag backup-exclude=true."
    echo -e "  Run ${BOLD}dr-cleanup.sh${NC} first to tag stopped instances, or tag manually:"
    echo -e "  aws ec2 create-tags --resources i-xxx --tags Key=backup-exclude,Value=true --region ${REGION}"
    exit 0
fi

echo -e "  Tagged instances:"
while IFS=$'\t' read -r inst_id state name; do
    echo -e "    - ${inst_id} (${name:-unnamed}) [${state}]"
done <<< "$EXCLUDED_INSTANCES"

# ─── Process Backup Plans ───────────────────────────────────────────────────
separator
echo ""
info "Fetching AWS Backup plans..."

BACKUP_PLANS_JSON=$(aws backup list-backup-plans \
    --query 'BackupPlansList[].{Id:BackupPlanId,Name:BackupPlanName}' \
    --output json --region "$REGION" 2>/dev/null || echo "[]")

PLAN_COUNT=$(echo "$BACKUP_PLANS_JSON" | jq length)

if [[ "$PLAN_COUNT" -eq 0 ]]; then
    info "No AWS Backup plans found."
    exit 0
fi

info "Found ${PLAN_COUNT} backup plan(s). Checking selections..."

UPDATED=0
SKIPPED=0
ALREADY_EXCLUDED=0

for PLAN_IDX in $(seq 0 $((PLAN_COUNT - 1))); do
    PLAN_ID=$(echo "$BACKUP_PLANS_JSON" | jq -r ".[$PLAN_IDX].Id")
    PLAN_NAME=$(echo "$BACKUP_PLANS_JSON" | jq -r ".[$PLAN_IDX].Name")

    SELECTIONS_JSON=$(aws backup list-backup-selections \
        --backup-plan-id "$PLAN_ID" \
        --query 'BackupSelectionsList[].{Id:SelectionId,Name:SelectionName}' \
        --output json --region "$REGION" 2>/dev/null || echo "[]")

    SEL_COUNT=$(echo "$SELECTIONS_JSON" | jq length)

    for SEL_IDX in $(seq 0 $((SEL_COUNT - 1))); do
        SEL_ID=$(echo "$SELECTIONS_JSON" | jq -r ".[$SEL_IDX].Id")
        SEL_NAME=$(echo "$SELECTIONS_JSON" | jq -r ".[$SEL_IDX].Name")

        # Get full selection detail
        SELECTION_DETAIL=$(aws backup get-backup-selection \
            --backup-plan-id "$PLAN_ID" \
            --selection-id "$SEL_ID" \
            --output json --region "$REGION" 2>/dev/null || echo "{}")

        BACKUP_SELECTION=$(echo "$SELECTION_DETAIL" | jq '.BackupSelection')

        # Check if it uses wildcard or tag-based (these are the ones that need exclusion)
        HAS_WILDCARD=$(echo "$BACKUP_SELECTION" | jq -r '.Resources[]? // empty' | grep -c '^\*$' || true)
        HAS_TAGS=$(echo "$BACKUP_SELECTION" | jq 'if .ListOfTags then (.ListOfTags | length) else 0 end')

        # Only process wildcard or tag-based selections
        if [[ "$HAS_WILDCARD" -eq 0 && "$HAS_TAGS" -eq 0 ]]; then
            info "Plan '${PLAN_NAME}' / Selection '${SEL_NAME}' - uses specific resource ARNs (not wildcard/tag-based)."
            info "  Tag-based exclusion does not apply. Use dr-cleanup.sh to remove stopped instances by ARN."
            continue
        fi

        # Check if exclusion already exists
        EXISTING_EXCLUSION=$(echo "$BACKUP_SELECTION" | jq '
            .Conditions.StringNotEquals // [] |
            map(select(.ConditionKey == "aws:ResourceTag/backup-exclude" and .ConditionValue == "true")) |
            length
        ' 2>/dev/null || echo "0")

        if [[ "$EXISTING_EXCLUSION" -gt 0 ]]; then
            info "Plan '${PLAN_NAME}' / Selection '${SEL_NAME}' - already has backup-exclude exclusion."
            ((ALREADY_EXCLUDED++))
            continue
        fi

        echo ""
        echo -e "  ${BOLD}Backup Plan:${NC}  ${PLAN_NAME} (${PLAN_ID})"
        echo -e "  ${BOLD}Selection:${NC}    ${SEL_NAME} (${SEL_ID})"
        if [[ "$HAS_WILDCARD" -gt 0 ]]; then
            echo -e "  Match Type:   ${YELLOW}Wildcard (*)${NC} - backs up ALL resources"
        else
            echo -e "  Match Type:   ${YELLOW}Tag-based${NC} (${HAS_TAGS} tag condition(s))"
        fi
        echo -e "  Current Exclusions: $(echo "$BACKUP_SELECTION" | jq '.Conditions.StringNotEquals // [] | length') StringNotEquals condition(s)"
        echo ""
        echo -e "  ${CYAN}Will add: Exclude resources where tag 'backup-exclude' = 'true'${NC}"

        if confirm "  Update this selection?"; then
            # Build the updated selection with the exclusion condition
            # AWS Backup uses Conditions.StringNotEquals for exclusions
            UPDATED_SELECTION=$(echo "$BACKUP_SELECTION" | jq '
                # Ensure Conditions object exists
                .Conditions = (.Conditions // {}) |
                # Ensure StringNotEquals array exists
                .Conditions.StringNotEquals = (.Conditions.StringNotEquals // []) |
                # Add the exclusion
                .Conditions.StringNotEquals += [{
                    "ConditionKey": "aws:ResourceTag/backup-exclude",
                    "ConditionValue": "true"
                }]
            ')

            # Delete old selection
            info "Deleting old selection..."
            aws backup delete-backup-selection \
                --backup-plan-id "$PLAN_ID" \
                --selection-id "$SEL_ID" \
                --region "$REGION" 2>/dev/null || {
                error "Failed to delete old selection. Skipping."
                ((SKIPPED++))
                continue
            }

            # Create updated selection
            info "Creating updated selection with exclusion..."
            NEW_SEL_RESULT=$(aws backup create-backup-selection \
                --backup-plan-id "$PLAN_ID" \
                --backup-selection "$UPDATED_SELECTION" \
                --output json \
                --region "$REGION" 2>&1) && {
                NEW_SEL_ID=$(echo "$NEW_SEL_RESULT" | jq -r '.SelectionId')
                success "Updated selection '${SEL_NAME}' (new ID: ${NEW_SEL_ID})"
                echo -e "    Instances tagged backup-exclude=true will now be skipped."
                ((UPDATED++))
            } || {
                error "Failed to create updated selection!"
                error "Output: ${NEW_SEL_RESULT}"
                echo ""
                warn "RECOVERY: The old selection was deleted. Recreating without exclusion..."
                aws backup create-backup-selection \
                    --backup-plan-id "$PLAN_ID" \
                    --backup-selection "$BACKUP_SELECTION" \
                    --region "$REGION" 2>/dev/null && \
                    warn "Original selection restored. No changes made." || \
                    error "CRITICAL: Could not restore original selection! Manual fix required for plan ${PLAN_ID}"
                ((SKIPPED++))
            }
        else
            info "Skipped."
            ((SKIPPED++))
        fi
    done
done

###############################################################################
# SUMMARY
###############################################################################
separator
echo -e "${BOLD}SUMMARY${NC}"
separator
echo -e "  Selections updated:          ${GREEN}${UPDATED}${NC}"
echo -e "  Selections skipped:          ${YELLOW}${SKIPPED}${NC}"
echo -e "  Already had exclusion:       ${CYAN}${ALREADY_EXCLUDED}${NC}"
echo ""

if [[ "$UPDATED" -gt 0 ]]; then
    success "Backup selections updated. Instances tagged backup-exclude=true will be"
    success "excluded from future backup jobs. Existing recovery points are NOT deleted."
    echo ""
    echo -e "  To remove the tag later and resume backups:"
    echo -e "  aws ec2 delete-tags --resources i-xxx --tags Key=backup-exclude --region ${REGION}"
fi
separator
echo ""
