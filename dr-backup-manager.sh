#!/bin/bash
###############################################################################
# DR Backup Manager
# Comprehensive AWS Backup management: audit, cleanup, create, and manage
# backup plans with cross-region DR copy to Ireland (eu-west-1)
#
# Usage:
#   ./dr-backup-manager.sh audit                          # Read-only scan
#   ./dr-backup-manager.sh cleanup                        # Remove waste + EIPs
#   ./dr-backup-manager.sh create --plan-name NAME \
#       --instance-ids "i-xxx i-yyy"                      # Create DR backup plan
#
# Options:
#   --region REGION           Source region (default: me-south-1)
#   --dr-region REGION        DR region (default: eu-west-1)
#   --local-retention DAYS    Local backup retention (default: 3)
#   --dr-retention DAYS       DR copy retention (default: 30)
#   --dry-run                 Show what would be done without making changes
#
# Requires: AWS CLI v2, jq
###############################################################################

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
SOURCE_REGION="${AWS_DEFAULT_REGION:-me-south-1}"
DR_REGION="eu-west-1"
PLAN_NAME=""
INSTANCE_IDS=""
LOCAL_RETENTION=3
DR_RETENTION=30
SCHEDULE="cron(0 1 * * ? *)"
DRY_RUN=false
COMMAND=""

# ─── Parse Arguments ─────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 {audit|cleanup|create} [options]"
    echo ""
    echo "Commands:"
    echo "  audit    Read-only scan of backup plans, stopped instances, and EIPs"
    echo "  cleanup  Remove wasteful backups, release unattached EIPs (with confirmation)"
    echo "  create   Create a new backup plan with daily DR copy to Ireland"
    echo ""
    echo "Options:"
    echo "  --region REGION           Source region (default: me-south-1)"
    echo "  --dr-region REGION        DR region (default: eu-west-1)"
    echo "  --plan-name NAME          Backup plan name (required for 'create')"
    echo "  --instance-ids \"i-x i-y\"  Instance IDs (required for 'create')"
    echo "  --local-retention DAYS    Local retention days (default: 3)"
    echo "  --dr-retention DAYS       DR copy retention days (default: 30)"
    echo "  --dry-run                 Preview only, no changes"
    exit 1
fi

COMMAND="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)          SOURCE_REGION="$2"; shift 2 ;;
        --dr-region)       DR_REGION="$2"; shift 2 ;;
        --plan-name)       PLAN_NAME="$2"; shift 2 ;;
        --instance-ids)    INSTANCE_IDS="$2"; shift 2 ;;
        --local-retention) LOCAL_RETENTION="$2"; shift 2 ;;
        --dr-retention)    DR_RETENTION="$2"; shift 2 ;;
        --schedule)        SCHEDULE="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        -h|--help)
            echo "Usage: $0 {audit|cleanup|create} [options]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helper Functions ────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*"; }
fatal()   { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

# Safe increment that won't trigger set -e
inc() { eval "$1=\$(( ${!1} + 1 ))"; }

confirm() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}  [DRY-RUN] Would ask: $1${NC}"
        return 1
    fi
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

get_instance_name() {
    local inst_id="$1"
    aws ec2 describe-instances \
        --instance-ids "$inst_id" \
        --query 'Reservations[0].Instances[0].Tags[?Key==`Name`].Value | [0]' \
        --output text --region "$SOURCE_REGION" 2>/dev/null || echo "unnamed"
}

# ─── Detect Account ─────────────────────────────────────────────────────────
separator
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${BOLD}AWS DR BACKUP MANAGER${NC} ${YELLOW}[DRY-RUN MODE]${NC}"
else
    echo -e "${BOLD}AWS DR BACKUP MANAGER${NC}"
fi
separator

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) || {
    fatal "Failed to get AWS account info. Check your credentials."
}
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "N/A")
CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)

echo -e "  Account:  ${BOLD}${ACCOUNT_ID}${NC} (${ACCOUNT_ALIAS})"
echo -e "  Region:   ${BOLD}${SOURCE_REGION}${NC}"
echo -e "  DR Region:${BOLD} ${DR_REGION}${NC}"
echo -e "  Identity: ${CALLER_ARN}"
echo -e "  Command:  ${BOLD}${COMMAND}${NC}"
echo -e "  Date:     $(date '+%Y-%m-%d %H:%M:%S')"
separator

###############################################################################
#                              AUDIT COMMAND
###############################################################################
do_audit() {
    echo -e "\n${BOLD}=== BACKUP AUDIT REPORT ===${NC}\n"

    # ─── 1. List all backup plans and their selections ───────────────────
    echo -e "${BOLD}1. BACKUP PLANS${NC}\n"

    BACKUP_PLANS_JSON=$(aws backup list-backup-plans \
        --query 'BackupPlansList[].{Id:BackupPlanId,Name:BackupPlanName}' \
        --output json --region "$SOURCE_REGION" 2>/dev/null || echo "[]")

    PLAN_COUNT=$(echo "$BACKUP_PLANS_JSON" | jq length)

    if [[ "$PLAN_COUNT" -eq 0 ]]; then
        warn "No AWS Backup plans found in ${SOURCE_REGION}."
    else
        for PLAN_IDX in $(seq 0 $((PLAN_COUNT - 1))); do
            PLAN_ID=$(echo "$BACKUP_PLANS_JSON" | jq -r ".[$PLAN_IDX].Id")
            PLAN_NAME_VAL=$(echo "$BACKUP_PLANS_JSON" | jq -r ".[$PLAN_IDX].Name")

            echo -e "  ${BOLD}Plan: ${PLAN_NAME_VAL}${NC} (${PLAN_ID})"

            # Get plan details for rules
            PLAN_DETAIL=$(aws backup get-backup-plan \
                --backup-plan-id "$PLAN_ID" \
                --region "$SOURCE_REGION" --output json 2>/dev/null || echo "{}")

            # Show rules
            RULE_COUNT=$(echo "$PLAN_DETAIL" | jq '.BackupPlan.Rules // [] | length')
            for R_IDX in $(seq 0 $((RULE_COUNT - 1))); do
                RULE_NAME=$(echo "$PLAN_DETAIL" | jq -r ".BackupPlan.Rules[$R_IDX].RuleName")
                RULE_SCHED=$(echo "$PLAN_DETAIL" | jq -r ".BackupPlan.Rules[$R_IDX].ScheduleExpression // \"not set\"")
                RULE_VAULT=$(echo "$PLAN_DETAIL" | jq -r ".BackupPlan.Rules[$R_IDX].TargetBackupVaultName")
                RULE_RETENTION=$(echo "$PLAN_DETAIL" | jq -r ".BackupPlan.Rules[$R_IDX].Lifecycle.DeleteAfterDays // \"forever\"")
                COPY_COUNT=$(echo "$PLAN_DETAIL" | jq ".BackupPlan.Rules[$R_IDX].CopyActions // [] | length")

                echo -e "    Rule: ${RULE_NAME}"
                echo -e "      Schedule:  ${RULE_SCHED}"
                echo -e "      Vault:     ${RULE_VAULT}"
                echo -e "      Retention: ${RULE_RETENTION} days"

                if [[ "$COPY_COUNT" -gt 0 ]]; then
                    for C_IDX in $(seq 0 $((COPY_COUNT - 1))); do
                        COPY_DEST=$(echo "$PLAN_DETAIL" | jq -r ".BackupPlan.Rules[$R_IDX].CopyActions[$C_IDX].DestinationBackupVaultArn")
                        COPY_RET=$(echo "$PLAN_DETAIL" | jq -r ".BackupPlan.Rules[$R_IDX].CopyActions[$C_IDX].Lifecycle.DeleteAfterDays // \"forever\"")
                        echo -e "      ${GREEN}DR Copy:${NC} ${COPY_DEST} (${COPY_RET} days)"
                    done
                else
                    echo -e "      ${YELLOW}DR Copy: NONE - no cross-region backup!${NC}"
                fi
            done

            # Get selections
            SELECTIONS_JSON=$(aws backup list-backup-selections \
                --backup-plan-id "$PLAN_ID" \
                --query 'BackupSelectionsList[].{Id:SelectionId,Name:SelectionName}' \
                --output json --region "$SOURCE_REGION" 2>/dev/null || echo "[]")

            SEL_COUNT=$(echo "$SELECTIONS_JSON" | jq length)

            if [[ "$SEL_COUNT" -eq 0 ]]; then
                echo -e "    ${RED}ORPHANED: No selections (plan does nothing)${NC}"
            else
                for SEL_IDX in $(seq 0 $((SEL_COUNT - 1))); do
                    SEL_ID=$(echo "$SELECTIONS_JSON" | jq -r ".[$SEL_IDX].Id")
                    SEL_NAME=$(echo "$SELECTIONS_JSON" | jq -r ".[$SEL_IDX].Name")

                    SELECTION_DETAIL=$(aws backup get-backup-selection \
                        --backup-plan-id "$PLAN_ID" \
                        --selection-id "$SEL_ID" \
                        --output json --region "$SOURCE_REGION" 2>/dev/null || echo "{}")

                    RESOURCES=$(echo "$SELECTION_DETAIL" | jq -r '.BackupSelection.Resources[]? // empty' 2>/dev/null || echo "")
                    HAS_WILDCARD=$(echo "$RESOURCES" | grep -c '^\*$' || true)

                    echo -e "    Selection: ${SEL_NAME:-unnamed} (${SEL_ID})"

                    if [[ "$HAS_WILDCARD" -gt 0 ]]; then
                        echo -e "      Type: ${YELLOW}Wildcard (*)${NC} - backs up ALL resources"
                    elif [[ -n "$RESOURCES" ]]; then
                        echo -e "      Type: Resource ARN list"
                        while IFS= read -r arn; do
                            [[ -z "$arn" ]] && continue
                            # Extract instance ID from ARN
                            INST_ID=$(echo "$arn" | grep -oP 'i-[a-f0-9]+' || echo "$arn")
                            if [[ "$INST_ID" =~ ^i- ]]; then
                                INST_STATE=$(aws ec2 describe-instances \
                                    --instance-ids "$INST_ID" \
                                    --query 'Reservations[0].Instances[0].State.Name' \
                                    --output text --region "$SOURCE_REGION" 2>/dev/null || echo "unknown")
                                INST_NAME=$(get_instance_name "$INST_ID")
                                if [[ "$INST_STATE" == "stopped" ]]; then
                                    echo -e "        ${RED}${INST_ID} (${INST_NAME}) - STOPPED (wasteful!)${NC}"
                                elif [[ "$INST_STATE" == "running" ]]; then
                                    echo -e "        ${GREEN}${INST_ID} (${INST_NAME}) - running${NC}"
                                else
                                    echo -e "        ${YELLOW}${INST_ID} (${INST_NAME}) - ${INST_STATE}${NC}"
                                fi
                            else
                                echo -e "        ${arn}"
                            fi
                        done <<< "$RESOURCES"
                    fi

                    # Check for exclusion conditions
                    EXCL_COUNT=$(echo "$SELECTION_DETAIL" | jq '.BackupSelection.Conditions.StringNotEquals // [] | length' 2>/dev/null || echo "0")
                    if [[ "$EXCL_COUNT" -gt 0 ]]; then
                        echo -e "      Exclusions: ${EXCL_COUNT} condition(s)"
                    fi
                done
            fi
            echo ""
        done
    fi

    # ─── 2. Stopped instances analysis ───────────────────────────────────
    separator
    echo -e "\n${BOLD}2. STOPPED EC2 INSTANCES${NC}\n"

    STOPPED_JSON=$(aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=stopped" \
        --query 'Reservations[].Instances[].[InstanceId, InstanceType, (Tags[?Key==`Name`].Value)[0], (Tags[?Key==`backup-exclude`].Value)[0]]' \
        --output json --region "$SOURCE_REGION" 2>/dev/null || echo "[]")

    STOPPED_COUNT=$(echo "$STOPPED_JSON" | jq length)

    if [[ "$STOPPED_COUNT" -eq 0 ]]; then
        info "No stopped instances found."
    else
        warn "Found ${STOPPED_COUNT} stopped instance(s):"
        for IDX in $(seq 0 $((STOPPED_COUNT - 1))); do
            INST_ID=$(echo "$STOPPED_JSON" | jq -r ".[$IDX][0]")
            INST_TYPE=$(echo "$STOPPED_JSON" | jq -r ".[$IDX][1]")
            INST_NAME=$(echo "$STOPPED_JSON" | jq -r ".[$IDX][2] // \"unnamed\"")
            EXCL_TAG=$(echo "$STOPPED_JSON" | jq -r ".[$IDX][3] // \"\"")

            EBS_SIZE=$(aws ec2 describe-volumes \
                --filters "Name=attachment.instance-id,Values=${INST_ID}" \
                --query 'sum(Volumes[].Size)' \
                --output text --region "$SOURCE_REGION" 2>/dev/null || echo "?")

            LINE="    ${INST_ID} (${INST_NAME}) - ${INST_TYPE} - ${EBS_SIZE} GB EBS"
            if [[ "$EXCL_TAG" == "true" ]]; then
                echo -e "${LINE} ${CYAN}[backup-exclude=true]${NC}"
            else
                echo -e "${LINE}"
            fi
        done
        echo ""
        echo -e "  EBS cost for stopped instances: ~\$$(echo "${STOPPED_COUNT} * 3" | bc)/mo (estimate)"
    fi

    # ─── 3. Elastic IPs ──────────────────────────────────────────────────
    separator
    echo -e "\n${BOLD}3. ELASTIC IPs${NC}\n"

    ALL_EIPS=$(aws ec2 describe-addresses --output json --region "$SOURCE_REGION" 2>/dev/null || echo '{"Addresses":[]}')
    TOTAL_EIPS=$(echo "$ALL_EIPS" | jq '.Addresses | length')

    WASTE_COUNT=0
    if [[ "$TOTAL_EIPS" -gt 0 ]]; then
        for IDX in $(seq 0 $((TOTAL_EIPS - 1))); do
            PUBLIC_IP=$(echo "$ALL_EIPS" | jq -r ".Addresses[$IDX].PublicIp")
            ALLOC_ID=$(echo "$ALL_EIPS" | jq -r ".Addresses[$IDX].AllocationId")
            ASSOC_ID=$(echo "$ALL_EIPS" | jq -r ".Addresses[$IDX].AssociationId // \"none\"")
            INST_ID=$(echo "$ALL_EIPS" | jq -r ".Addresses[$IDX].InstanceId // \"none\"")
            TAGS=$(echo "$ALL_EIPS" | jq -r ".Addresses[$IDX].Tags // [] | map(\"\(.Key)=\(.Value)\") | join(\", \")")

            if [[ "$ASSOC_ID" == "none" || "$ASSOC_ID" == "null" ]]; then
                echo -e "  ${RED}${PUBLIC_IP}${NC} (${ALLOC_ID}) - ${RED}UNATTACHED${NC} (~\$3.65/mo waste)"
                [[ -n "$TAGS" ]] && echo -e "    Tags: ${TAGS}"
                inc WASTE_COUNT
            elif [[ "$INST_ID" != "none" && "$INST_ID" != "null" ]]; then
                INST_STATE=$(aws ec2 describe-instances \
                    --instance-ids "$INST_ID" \
                    --query 'Reservations[0].Instances[0].State.Name' \
                    --output text --region "$SOURCE_REGION" 2>/dev/null || echo "unknown")
                INST_NAME=$(get_instance_name "$INST_ID")

                if [[ "$INST_STATE" == "stopped" ]]; then
                    echo -e "  ${YELLOW}${PUBLIC_IP}${NC} (${ALLOC_ID}) -> ${INST_ID} (${INST_NAME}) - ${RED}STOPPED${NC} (~\$3.65/mo waste)"
                    inc WASTE_COUNT
                else
                    echo -e "  ${GREEN}${PUBLIC_IP}${NC} (${ALLOC_ID}) -> ${INST_ID} (${INST_NAME}) - ${GREEN}${INST_STATE}${NC}"
                fi
            else
                echo -e "  ${GREEN}${PUBLIC_IP}${NC} (${ALLOC_ID}) -> ENI attached"
            fi
        done
    fi
    echo ""
    if [[ "$WASTE_COUNT" -gt 0 ]]; then
        echo -e "  ${YELLOW}Wasted EIPs: ${WASTE_COUNT} (~\$$(echo "$WASTE_COUNT * 3.65" | bc)/mo)${NC}"
    else
        info "No wasted Elastic IPs."
    fi

    # ─── 4. DR Vault status ──────────────────────────────────────────────
    separator
    echo -e "\n${BOLD}4. DR VAULT STATUS (${DR_REGION})${NC}\n"

    DR_VAULTS=$(aws backup list-backup-vaults \
        --query 'BackupVaultList[].{Name:BackupVaultName,Points:NumberOfRecoveryPoints}' \
        --output json --region "$DR_REGION" 2>/dev/null || echo "[]")

    DR_VAULT_COUNT=$(echo "$DR_VAULTS" | jq length)

    if [[ "$DR_VAULT_COUNT" -eq 0 ]]; then
        warn "No backup vaults found in ${DR_REGION}. DR copies not configured."
    else
        for IDX in $(seq 0 $((DR_VAULT_COUNT - 1))); do
            V_NAME=$(echo "$DR_VAULTS" | jq -r ".[$IDX].Name")
            V_POINTS=$(echo "$DR_VAULTS" | jq -r ".[$IDX].Points")
            echo -e "  ${V_NAME}: ${V_POINTS} recovery point(s)"
        done
    fi

    separator
    echo -e "\n${BOLD}AUDIT COMPLETE${NC} - No changes were made.\n"
}

###############################################################################
#                             CLEANUP COMMAND
###############################################################################
do_cleanup() {
    BACKUP_CLEANED=0
    BACKUP_SKIPPED=0
    EIP_RELEASED=0
    EIP_SKIPPED=0
    PLANS_DELETED=0

    # ─── Section 1: Wasteful Backups on Stopped Instances ────────────────
    echo -e "\n${BOLD}SECTION 1: AWS Backup on Stopped EC2 Instances${NC}\n"

    info "Fetching stopped EC2 instances..."
    STOPPED_INSTANCES=$(aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text --region "$SOURCE_REGION" 2>/dev/null || echo "")

    if [[ -z "$STOPPED_INSTANCES" ]]; then
        info "No stopped EC2 instances found."
    else
        STOPPED_COUNT=$(echo "$STOPPED_INSTANCES" | wc -w | tr -d ' ')
        info "Found ${STOPPED_COUNT} stopped instance(s)."

        info "Fetching AWS Backup plans..."
        BACKUP_PLANS_JSON=$(aws backup list-backup-plans \
            --query 'BackupPlansList[].{Id:BackupPlanId,Name:BackupPlanName}' \
            --output json --region "$SOURCE_REGION" 2>/dev/null || echo "[]")

        PLAN_COUNT=$(echo "$BACKUP_PLANS_JSON" | jq length)

        if [[ "$PLAN_COUNT" -eq 0 ]]; then
            info "No AWS Backup plans found."
        else
            info "Found ${PLAN_COUNT} backup plan(s). Checking selections..."

            for PLAN_IDX in $(seq 0 $((PLAN_COUNT - 1))); do
                PLAN_ID=$(echo "$BACKUP_PLANS_JSON" | jq -r ".[$PLAN_IDX].Id")
                PLAN_NAME_VAL=$(echo "$BACKUP_PLANS_JSON" | jq -r ".[$PLAN_IDX].Name")

                SELECTIONS_JSON=$(aws backup list-backup-selections \
                    --backup-plan-id "$PLAN_ID" \
                    --query 'BackupSelectionsList[].{Id:SelectionId,Name:SelectionName}' \
                    --output json --region "$SOURCE_REGION" 2>/dev/null || echo "[]")

                SEL_COUNT=$(echo "$SELECTIONS_JSON" | jq length)

                # Detect orphaned plans (no selections)
                if [[ "$SEL_COUNT" -eq 0 ]]; then
                    echo ""
                    warn "ORPHANED BACKUP PLAN: '${PLAN_NAME_VAL}' (${PLAN_ID})"
                    echo -e "    This plan has no selections and does nothing."
                    if confirm "    Delete orphaned plan '${PLAN_NAME_VAL}'?"; then
                        aws backup delete-backup-plan \
                            --backup-plan-id "$PLAN_ID" \
                            --region "$SOURCE_REGION" 2>/dev/null && \
                            success "Deleted orphaned plan '${PLAN_NAME_VAL}'" || \
                            err "Failed to delete plan"
                        inc PLANS_DELETED
                    else
                        info "Skipped."
                    fi
                    continue
                fi

                for SEL_IDX in $(seq 0 $((SEL_COUNT - 1))); do
                    SEL_ID=$(echo "$SELECTIONS_JSON" | jq -r ".[$SEL_IDX].Id")
                    SEL_NAME=$(echo "$SELECTIONS_JSON" | jq -r ".[$SEL_IDX].Name")

                    SELECTION_DETAIL=$(aws backup get-backup-selection \
                        --backup-plan-id "$PLAN_ID" \
                        --selection-id "$SEL_ID" \
                        --output json --region "$SOURCE_REGION" 2>/dev/null || echo "{}")

                    BACKUP_SELECTION=$(echo "$SELECTION_DETAIL" | jq '.BackupSelection' 2>/dev/null || echo "{}")
                    RESOURCE_ARNS=$(echo "$BACKUP_SELECTION" | jq -r '.Resources[]? // empty' 2>/dev/null || echo "")
                    HAS_WILDCARD=$(echo "$RESOURCE_ARNS" | grep -c '^\*$' || true)

                    # ── Case A: Specific resource ARNs ──
                    if [[ -n "$RESOURCE_ARNS" && "$HAS_WILDCARD" -eq 0 ]]; then
                        FOUND_STOPPED=false
                        STOPPED_IN_SEL=()

                        for INST_ID in $STOPPED_INSTANCES; do
                            if echo "$RESOURCE_ARNS" | grep -q "$INST_ID"; then
                                STOPPED_IN_SEL+=("$INST_ID")
                                FOUND_STOPPED=true
                            fi
                        done

                        if [[ "$FOUND_STOPPED" == true ]]; then
                            RESOURCE_COUNT=$(echo "$RESOURCE_ARNS" | grep -c . || true)
                            STOPPED_IN_COUNT=${#STOPPED_IN_SEL[@]}
                            RUNNING_IN_COUNT=$((RESOURCE_COUNT - STOPPED_IN_COUNT))

                            echo ""
                            warn "WASTEFUL BACKUP FOUND in plan '${PLAN_NAME_VAL}':"
                            echo -e "    Selection: ${SEL_NAME:-unnamed} (${SEL_ID})"
                            echo -e "    Total resources: ${RESOURCE_COUNT} (${STOPPED_IN_COUNT} stopped, ${RUNNING_IN_COUNT} running)"
                            echo ""

                            for INST_ID in "${STOPPED_IN_SEL[@]}"; do
                                INST_NAME=$(get_instance_name "$INST_ID")

                                RP_COUNT=$(aws backup list-recovery-points-by-resource \
                                    --resource-arn "arn:aws:ec2:${SOURCE_REGION}:${ACCOUNT_ID}:instance/${INST_ID}" \
                                    --query 'length(RecoveryPoints)' \
                                    --output text --region "$SOURCE_REGION" 2>/dev/null || echo "?")

                                echo -e "    ${RED}STOPPED:${NC} ${INST_ID} (${INST_NAME}) - ${RP_COUNT} recovery points"
                            done
                            echo ""

                            if [[ "$RUNNING_IN_COUNT" -eq 0 ]]; then
                                # All resources are stopped
                                echo -e "    ${YELLOW}All resources in this selection are stopped.${NC}"
                                if confirm "    Delete entire selection '${SEL_NAME:-unnamed}'?"; then
                                    aws backup delete-backup-selection \
                                        --backup-plan-id "$PLAN_ID" \
                                        --selection-id "$SEL_ID" \
                                        --region "$SOURCE_REGION" 2>/dev/null && \
                                        success "Deleted selection '${SEL_NAME:-unnamed}'" || \
                                        err "Failed to delete selection"
                                    inc BACKUP_CLEANED
                                else
                                    info "Skipped."
                                    inc BACKUP_SKIPPED
                                fi
                            else
                                # Mix of running and stopped - recreate without stopped
                                echo -e "    ${YELLOW}Selection also includes ${RUNNING_IN_COUNT} running instance(s).${NC}"
                                echo -e "    Will recreate selection keeping only running instances."

                                if confirm "    Remove ${STOPPED_IN_COUNT} stopped instance(s) from selection?"; then
                                    # Build exclusion pattern
                                    GREP_PATTERN=$(printf '%s\|' "${STOPPED_IN_SEL[@]}" | sed 's/\\|$//')
                                    NEW_RESOURCES=$(echo "$RESOURCE_ARNS" | grep -v "$GREP_PATTERN" | jq -R -s 'split("\n") | map(select(length > 0))')

                                    NEW_SELECTION=$(echo "$BACKUP_SELECTION" | jq --argjson res "$NEW_RESOURCES" \
                                        '.Resources = $res')

                                    # Save original for rollback
                                    ORIGINAL_SELECTION="$BACKUP_SELECTION"

                                    info "Deleting old selection..."
                                    if ! aws backup delete-backup-selection \
                                        --backup-plan-id "$PLAN_ID" \
                                        --selection-id "$SEL_ID" \
                                        --region "$SOURCE_REGION" 2>/dev/null; then
                                        err "Failed to delete old selection. No changes made."
                                        inc BACKUP_SKIPPED
                                        continue
                                    fi

                                    info "Recreating selection without stopped instances..."
                                    if aws backup create-backup-selection \
                                        --backup-plan-id "$PLAN_ID" \
                                        --backup-selection "$NEW_SELECTION" \
                                        --region "$SOURCE_REGION" 2>/dev/null; then
                                        success "Selection recreated without stopped instances."
                                        inc BACKUP_CLEANED
                                    else
                                        err "Failed to create new selection!"
                                        warn "ROLLING BACK: Restoring original selection..."
                                        if aws backup create-backup-selection \
                                            --backup-plan-id "$PLAN_ID" \
                                            --backup-selection "$ORIGINAL_SELECTION" \
                                            --region "$SOURCE_REGION" 2>/dev/null; then
                                            warn "Original selection restored. No net changes."
                                        else
                                            err "CRITICAL: Rollback failed! Plan ${PLAN_ID} has no selection."
                                            err "Manual fix required. Original selection JSON:"
                                            echo "$ORIGINAL_SELECTION" | jq .
                                        fi
                                        inc BACKUP_SKIPPED
                                    fi
                                else
                                    info "Skipped."
                                    inc BACKUP_SKIPPED
                                fi
                            fi
                        else
                            info "Plan '${PLAN_NAME_VAL}' / Selection '${SEL_NAME:-unnamed}' - no stopped instances targeted."
                        fi
                    fi

                    # ── Case B: Wildcard / Tag-based ──
                    if [[ "$HAS_WILDCARD" -gt 0 ]]; then
                        # Check if stopped instances have recovery points
                        MATCHED_STOPPED=()
                        for INST_ID in $STOPPED_INSTANCES; do
                            RP_COUNT=$(aws backup list-recovery-points-by-resource \
                                --resource-arn "arn:aws:ec2:${SOURCE_REGION}:${ACCOUNT_ID}:instance/${INST_ID}" \
                                --query 'length(RecoveryPoints)' \
                                --output text --region "$SOURCE_REGION" 2>/dev/null || echo "0")

                            if [[ "$RP_COUNT" -gt 0 && "$RP_COUNT" != "0" ]]; then
                                MATCHED_STOPPED+=("${INST_ID}:${RP_COUNT}")
                            fi
                        done

                        if [[ ${#MATCHED_STOPPED[@]} -gt 0 ]]; then
                            echo ""
                            warn "WILDCARD BACKUP includes stopped instances:"
                            echo -e "    Plan: ${PLAN_NAME_VAL} / Selection: ${SEL_NAME:-unnamed}"
                            echo -e "    Type: ${YELLOW}Wildcard (*)${NC} - cannot remove individual instances"
                            echo ""

                            for ENTRY in "${MATCHED_STOPPED[@]}"; do
                                INST_ID="${ENTRY%%:*}"
                                RP="${ENTRY##*:}"
                                INST_NAME=$(get_instance_name "$INST_ID")
                                echo -e "      ${RED}${INST_ID} (${INST_NAME}) - ${RP} recovery points${NC}"
                            done

                            echo ""
                            echo -e "    ${CYAN}Solution: Add exclusion condition for tag 'backup-exclude=true'${NC}"

                            if confirm "    Tag stopped instances with backup-exclude=true AND add exclusion to selection?"; then
                                # Tag stopped instances
                                for INST_ID in $STOPPED_INSTANCES; do
                                    aws ec2 create-tags \
                                        --resources "$INST_ID" \
                                        --tags "Key=backup-exclude,Value=true" \
                                        --region "$SOURCE_REGION" 2>/dev/null && \
                                        success "Tagged ${INST_ID}" || \
                                        err "Failed to tag ${INST_ID}"
                                done

                                # Add exclusion condition to selection
                                EXISTING_EXCLUSION=$(echo "$BACKUP_SELECTION" | jq '
                                    .Conditions.StringNotEquals // [] |
                                    map(select(.ConditionKey == "aws:ResourceTag/backup-exclude" and .ConditionValue == "true")) |
                                    length
                                ' 2>/dev/null || echo "0")

                                if [[ "$EXISTING_EXCLUSION" -gt 0 ]]; then
                                    info "Exclusion condition already exists on this selection."
                                else
                                    UPDATED_SELECTION=$(echo "$BACKUP_SELECTION" | jq '
                                        .Conditions = (.Conditions // {}) |
                                        .Conditions.StringNotEquals = (.Conditions.StringNotEquals // []) |
                                        .Conditions.StringNotEquals += [{
                                            "ConditionKey": "aws:ResourceTag/backup-exclude",
                                            "ConditionValue": "true"
                                        }]
                                    ')

                                    ORIGINAL_SELECTION="$BACKUP_SELECTION"

                                    info "Updating selection with exclusion condition..."
                                    if ! aws backup delete-backup-selection \
                                        --backup-plan-id "$PLAN_ID" \
                                        --selection-id "$SEL_ID" \
                                        --region "$SOURCE_REGION" 2>/dev/null; then
                                        err "Failed to delete old selection."
                                        inc BACKUP_SKIPPED
                                        continue
                                    fi

                                    if aws backup create-backup-selection \
                                        --backup-plan-id "$PLAN_ID" \
                                        --backup-selection "$UPDATED_SELECTION" \
                                        --region "$SOURCE_REGION" 2>/dev/null; then
                                        success "Selection updated with backup-exclude exclusion."
                                        inc BACKUP_CLEANED
                                    else
                                        err "Failed to update selection!"
                                        warn "ROLLING BACK..."
                                        aws backup create-backup-selection \
                                            --backup-plan-id "$PLAN_ID" \
                                            --backup-selection "$ORIGINAL_SELECTION" \
                                            --region "$SOURCE_REGION" 2>/dev/null && \
                                            warn "Restored original selection." || \
                                            err "CRITICAL: Rollback failed! Manual fix needed for plan ${PLAN_ID}"
                                        inc BACKUP_SKIPPED
                                    fi
                                fi
                                inc BACKUP_CLEANED
                            else
                                info "Skipped."
                                inc BACKUP_SKIPPED
                            fi
                        else
                            info "Plan '${PLAN_NAME_VAL}' - wildcard selection, no stopped instances have recovery points."
                        fi
                    fi
                done
            done
        fi
    fi

    # ─── Section 2: Unattached Elastic IPs ───────────────────────────────
    separator
    echo -e "\n${BOLD}SECTION 2: Unattached Elastic IPs${NC}\n"

    info "Fetching Elastic IPs..."

    ALL_EIPS=$(aws ec2 describe-addresses --output json --region "$SOURCE_REGION" 2>/dev/null || echo '{"Addresses":[]}')
    TOTAL_EIPS=$(echo "$ALL_EIPS" | jq '.Addresses | length')

    for IDX in $(seq 0 $((TOTAL_EIPS - 1))); do
        PUBLIC_IP=$(echo "$ALL_EIPS" | jq -r ".Addresses[$IDX].PublicIp")
        ALLOC_ID=$(echo "$ALL_EIPS" | jq -r ".Addresses[$IDX].AllocationId")
        ASSOC_ID=$(echo "$ALL_EIPS" | jq -r ".Addresses[$IDX].AssociationId // \"none\"")
        INST_ID=$(echo "$ALL_EIPS" | jq -r ".Addresses[$IDX].InstanceId // \"none\"")
        TAGS=$(echo "$ALL_EIPS" | jq -r ".Addresses[$IDX].Tags // [] | map(\"\(.Key)=\(.Value)\") | join(\", \")")

        IS_WASTE=false
        INST_NAME=""
        INST_STATE=""

        # Check if unattached
        if [[ "$ASSOC_ID" == "none" || "$ASSOC_ID" == "null" ]]; then
            IS_WASTE=true
        elif [[ "$INST_ID" != "none" && "$INST_ID" != "null" ]]; then
            INST_STATE=$(aws ec2 describe-instances \
                --instance-ids "$INST_ID" \
                --query 'Reservations[0].Instances[0].State.Name' \
                --output text --region "$SOURCE_REGION" 2>/dev/null || echo "unknown")
            INST_NAME=$(get_instance_name "$INST_ID")
            [[ "$INST_STATE" == "stopped" ]] && IS_WASTE=true
        fi

        if [[ "$IS_WASTE" == false ]]; then
            continue
        fi

        echo ""
        echo -e "  ${BOLD}Elastic IP: ${PUBLIC_IP}${NC} (${ALLOC_ID})"
        [[ -n "$TAGS" ]] && echo -e "    Tags: ${TAGS}"

        if [[ "$ASSOC_ID" == "none" || "$ASSOC_ID" == "null" ]]; then
            echo -e "    Status: ${RED}UNATTACHED${NC} (~\$3.65/mo)"

            if confirm "    Release ${PUBLIC_IP}?"; then
                aws ec2 release-address \
                    --allocation-id "$ALLOC_ID" \
                    --region "$SOURCE_REGION" 2>/dev/null && \
                    success "Released ${PUBLIC_IP}" || \
                    err "Failed to release ${PUBLIC_IP}"
                inc EIP_RELEASED
            else
                info "Skipped."
                inc EIP_SKIPPED
            fi
        else
            echo -e "    Attached to: ${INST_ID} (${INST_NAME}) - ${RED}STOPPED${NC} (~\$3.65/mo)"

            if confirm "    Disassociate ${PUBLIC_IP} from stopped instance ${INST_ID}?"; then
                aws ec2 disassociate-address \
                    --association-id "$ASSOC_ID" \
                    --region "$SOURCE_REGION" 2>/dev/null && \
                    success "Disassociated ${PUBLIC_IP} from ${INST_ID}" || \
                    { err "Failed to disassociate"; continue; }

                if confirm "    Also release ${PUBLIC_IP}? ('n' keeps it unattached)"; then
                    aws ec2 release-address \
                        --allocation-id "$ALLOC_ID" \
                        --region "$SOURCE_REGION" 2>/dev/null && \
                        success "Released ${PUBLIC_IP}" || \
                        err "Failed to release ${PUBLIC_IP}"
                fi
                inc EIP_RELEASED
            else
                info "Skipped."
                inc EIP_SKIPPED
            fi
        fi
    done

    if [[ "$EIP_RELEASED" -eq 0 && "$EIP_SKIPPED" -eq 0 ]]; then
        info "No wasted Elastic IPs found."
    fi

    # ─── Summary ─────────────────────────────────────────────────────────
    separator
    echo -e "${BOLD}CLEANUP SUMMARY${NC}"
    separator
    echo -e "  Account:  ${ACCOUNT_ID} (${ACCOUNT_ALIAS})"
    echo -e "  Region:   ${SOURCE_REGION}"
    echo ""
    echo -e "  ${BOLD}AWS Backup:${NC}"
    echo -e "    Cleaned:        ${GREEN}${BACKUP_CLEANED}${NC}"
    echo -e "    Skipped:        ${YELLOW}${BACKUP_SKIPPED}${NC}"
    echo -e "    Plans deleted:  ${GREEN}${PLANS_DELETED}${NC}"
    echo ""
    echo -e "  ${BOLD}Elastic IPs:${NC}"
    echo -e "    Released: ${GREEN}${EIP_RELEASED}${NC}"
    echo -e "    Skipped:  ${YELLOW}${EIP_SKIPPED}${NC}"
    echo ""

    TOTAL_SAVINGS=$(echo "($BACKUP_CLEANED * 10) + ($EIP_RELEASED * 3.65)" | bc 2>/dev/null || echo "N/A")
    echo -e "  ${BOLD}Estimated Monthly Savings: ~\$${TOTAL_SAVINGS}${NC}"
    separator
    echo ""
}

###############################################################################
#                             CREATE COMMAND
###############################################################################
do_create() {
    if [[ -z "$INSTANCE_IDS" ]]; then
        fatal "Missing --instance-ids. Example: --instance-ids \"i-1234567890abcdef0 i-0987654321fedcba0\""
    fi
    if [[ -z "$PLAN_NAME" ]]; then
        fatal "Missing --plan-name. Example: --plan-name \"DailyBackupToIreland\""
    fi

    # ─── Step 1: Validate Instances ──────────────────────────────────────
    echo -e "\n${BOLD}STEP 1: Validate Target Instances${NC}\n"

    RESOURCE_ARNS=()
    for INST_ID in $INSTANCE_IDS; do
        INST_INFO=$(aws ec2 describe-instances \
            --instance-ids "$INST_ID" \
            --query 'Reservations[0].Instances[0].[State.Name, InstanceType, (Tags[?Key==`Name`].Value)[0]]' \
            --output text --region "$SOURCE_REGION" 2>/dev/null) || {
            fatal "Instance ${INST_ID} not found in ${SOURCE_REGION}."
        }

        INST_STATE=$(echo "$INST_INFO" | awk '{print $1}')
        INST_TYPE=$(echo "$INST_INFO" | awk '{print $2}')
        INST_NAME=$(echo "$INST_INFO" | awk '{print $3}')

        if [[ "$INST_STATE" == "stopped" ]]; then
            warn "${INST_ID} (${INST_NAME}) is STOPPED. Backing up a stopped instance creates identical snapshots daily."
            if ! confirm "  Include this stopped instance anyway?"; then
                info "Skipping ${INST_ID}."
                continue
            fi
        fi

        echo -e "  ${GREEN}✓${NC} ${INST_ID} - ${INST_NAME:-unnamed} (${INST_TYPE}, ${INST_STATE})"
        RESOURCE_ARNS+=("arn:aws:ec2:${SOURCE_REGION}:${ACCOUNT_ID}:instance/${INST_ID}")
    done

    if [[ ${#RESOURCE_ARNS[@]} -eq 0 ]]; then
        fatal "No instances selected."
    fi

    # ─── Step 2: Backup Vaults ───────────────────────────────────────────
    separator
    echo -e "\n${BOLD}STEP 2: Ensure Backup Vaults Exist${NC}\n"

    SOURCE_VAULT="Default"
    if aws backup describe-backup-vault \
        --backup-vault-name "$SOURCE_VAULT" \
        --region "$SOURCE_REGION" &>/dev/null; then
        success "Source vault '${SOURCE_VAULT}' exists in ${SOURCE_REGION}"
    else
        info "Creating vault '${SOURCE_VAULT}' in ${SOURCE_REGION}..."
        aws backup create-backup-vault \
            --backup-vault-name "$SOURCE_VAULT" \
            --region "$SOURCE_REGION" &>/dev/null || fatal "Failed to create source vault"
        success "Created vault '${SOURCE_VAULT}' in ${SOURCE_REGION}"
    fi

    DR_VAULT="DR-Backup-Vault"
    if aws backup describe-backup-vault \
        --backup-vault-name "$DR_VAULT" \
        --region "$DR_REGION" &>/dev/null; then
        success "DR vault '${DR_VAULT}' exists in ${DR_REGION}"
    else
        info "Creating vault '${DR_VAULT}' in ${DR_REGION}..."
        aws backup create-backup-vault \
            --backup-vault-name "$DR_VAULT" \
            --region "$DR_REGION" &>/dev/null || fatal "Failed to create DR vault"
        success "Created vault '${DR_VAULT}' in ${DR_REGION}"
    fi

    DR_VAULT_ARN="arn:aws:backup:${DR_REGION}:${ACCOUNT_ID}:backup-vault:${DR_VAULT}"

    # ─── Step 3: IAM Role ────────────────────────────────────────────────
    separator
    echo -e "\n${BOLD}STEP 3: Ensure Backup IAM Role${NC}\n"

    ROLE_NAME="AWSBackupServiceRole-${PLAN_NAME}"

    if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
        success "IAM role '${ROLE_NAME}' already exists"
        ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)
    else
        info "Creating IAM role '${ROLE_NAME}'..."

        TRUST_POLICY='{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "backup.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }'

        aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document "$TRUST_POLICY" \
            --description "AWS Backup role for ${PLAN_NAME}" &>/dev/null || fatal "Failed to create IAM role"

        aws iam attach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup" 2>/dev/null

        aws iam attach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores" 2>/dev/null

        ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)
        success "Created IAM role: ${ROLE_ARN}"

        info "Waiting 10 seconds for IAM role propagation..."
        sleep 10
    fi

    # ─── Step 4: Create Backup Plan ──────────────────────────────────────
    separator
    echo -e "\n${BOLD}STEP 4: Create Backup Plan${NC}\n"

    # Check for existing plan
    EXISTING_PLAN_ID=$(aws backup list-backup-plans \
        --query "BackupPlansList[?BackupPlanName=='${PLAN_NAME}'].BackupPlanId | [0]" \
        --output text --region "$SOURCE_REGION" 2>/dev/null || echo "None")

    if [[ "$EXISTING_PLAN_ID" != "None" && -n "$EXISTING_PLAN_ID" ]]; then
        warn "Backup plan '${PLAN_NAME}' already exists (ID: ${EXISTING_PLAN_ID})."
        if ! confirm "Delete and recreate it?"; then
            info "Keeping existing plan. Exiting."
            return
        fi
        aws backup delete-backup-plan \
            --backup-plan-id "$EXISTING_PLAN_ID" \
            --region "$SOURCE_REGION" 2>/dev/null
        success "Deleted old plan."
    fi

    echo ""
    echo -e "  ${BOLD}Plan configuration:${NC}"
    echo -e "    Name:            ${PLAN_NAME}"
    echo -e "    Schedule:        Daily at 1:00 AM UTC"
    echo -e "    Local vault:     ${SOURCE_VAULT} (${SOURCE_REGION})"
    echo -e "    Local retention: ${LOCAL_RETENTION} days"
    echo -e "    DR vault:        ${DR_VAULT} (${DR_REGION})"
    echo -e "    DR retention:    ${DR_RETENTION} days"
    echo -e "    Instances:       ${#RESOURCE_ARNS[@]}"
    echo ""

    if ! confirm "  Create this backup plan?"; then
        info "Cancelled."
        return
    fi

    BACKUP_PLAN_JSON=$(cat <<PLANEOF
{
    "BackupPlanName": "${PLAN_NAME}",
    "Rules": [
        {
            "RuleName": "DailyBackupWithDRCopy",
            "TargetBackupVaultName": "${SOURCE_VAULT}",
            "ScheduleExpression": "${SCHEDULE}",
            "StartWindowMinutes": 60,
            "CompletionWindowMinutes": 180,
            "Lifecycle": {
                "DeleteAfterDays": ${LOCAL_RETENTION}
            },
            "CopyActions": [
                {
                    "DestinationBackupVaultArn": "${DR_VAULT_ARN}",
                    "Lifecycle": {
                        "DeleteAfterDays": ${DR_RETENTION}
                    }
                }
            ]
        }
    ]
}
PLANEOF
)

    info "Creating backup plan..."
    PLAN_RESULT=$(aws backup create-backup-plan \
        --backup-plan "$BACKUP_PLAN_JSON" \
        --region "$SOURCE_REGION" \
        --output json 2>/dev/null) || fatal "Failed to create backup plan."

    PLAN_ID=$(echo "$PLAN_RESULT" | jq -r '.BackupPlanId')
    success "Created backup plan: ${PLAN_NAME} (${PLAN_ID})"

    # ─── Step 5: Create Selection ────────────────────────────────────────
    separator
    echo -e "\n${BOLD}STEP 5: Assign Instances${NC}\n"

    RESOURCE_JSON=$(printf '%s\n' "${RESOURCE_ARNS[@]}" | jq -R . | jq -s .)

    SELECTION_JSON=$(cat <<SELEOF
{
    "SelectionName": "${PLAN_NAME}-Selection",
    "IamRoleArn": "${ROLE_ARN}",
    "Resources": ${RESOURCE_JSON}
}
SELEOF
)

    info "Creating backup selection..."
    SEL_RESULT=$(aws backup create-backup-selection \
        --backup-plan-id "$PLAN_ID" \
        --backup-selection "$SELECTION_JSON" \
        --region "$SOURCE_REGION" \
        --output json 2>/dev/null) || fatal "Failed to create backup selection."

    SEL_ID=$(echo "$SEL_RESULT" | jq -r '.SelectionId')
    success "Created selection: ${PLAN_NAME}-Selection (${SEL_ID})"

    # ─── Step 6: Trigger Initial Backup ──────────────────────────────────
    separator
    echo -e "\n${BOLD}STEP 6: Trigger Initial Backup${NC}\n"

    info "Triggering on-demand backup for each instance (schedule continues independently)..."
    echo ""

    for ARN in "${RESOURCE_ARNS[@]}"; do
        INST_ID=$(echo "$ARN" | grep -oE 'i-[a-f0-9]+')
        INST_NAME=$(get_instance_name "$INST_ID")

        info "Starting backup for ${INST_ID} (${INST_NAME})..."
        JOB_RESULT=$(aws backup start-backup-job \
            --backup-vault-name "$SOURCE_VAULT" \
            --resource-arn "$ARN" \
            --iam-role-arn "$ROLE_ARN" \
            --lifecycle "DeleteAfterDays=${LOCAL_RETENTION}" \
            --region "$SOURCE_REGION" \
            --output json 2>&1) && {
            JOB_ID=$(echo "$JOB_RESULT" | jq -r '.BackupJobId')
            success "Backup job started: ${JOB_ID}"
            echo -e "    Monitor: aws backup describe-backup-job --backup-job-id ${JOB_ID} --region ${SOURCE_REGION}"
        } || {
            warn "Could not start on-demand backup: ${JOB_RESULT}"
            warn "The scheduled backup at 1:00 AM UTC will still run."
        }
    done

    echo ""
    info "Once local backups complete, copy to DR with:"
    echo -e "    ${CYAN}# Get recovery point ARN from completed job"
    echo "    RP_ARN=\$(aws backup describe-backup-job --backup-job-id <JOB_ID> --region ${SOURCE_REGION} --query 'RecoveryPointArn' --output text)"
    echo "    aws backup start-copy-job \\"
    echo "        --recovery-point-arn \"\$RP_ARN\" \\"
    echo "        --source-backup-vault-name ${SOURCE_VAULT} \\"
    echo "        --destination-backup-vault-arn ${DR_VAULT_ARN} \\"
    echo "        --iam-role-arn ${ROLE_ARN} \\"
    echo "        --lifecycle DeleteAfterDays=${DR_RETENTION} \\"
    echo -e "        --region ${SOURCE_REGION}${NC}"
    echo ""
    info "Scheduled backups (daily 1:00 AM UTC) will handle both backup + DR copy automatically."

    # ─── Summary ─────────────────────────────────────────────────────────
    separator
    echo -e "${BOLD}BACKUP PLAN CREATED SUCCESSFULLY${NC}"
    separator
    echo ""
    echo -e "  ${BOLD}Backup Flow:${NC}"
    echo -e "    Daily at 1:00 AM UTC:"
    echo -e "    1. Snapshot in ${SOURCE_REGION} (vault: ${SOURCE_VAULT})"
    echo -e "    2. Copy to ${DR_REGION} (vault: ${DR_VAULT})"
    echo -e "    3. Delete local after ${LOCAL_RETENTION} days"
    echo -e "    4. Delete DR copy after ${DR_RETENTION} days"
    echo ""
    echo -e "  ${BOLD}Protected Instances:${NC}"
    for INST_ID in $INSTANCE_IDS; do
        INST_NAME=$(get_instance_name "$INST_ID")
        echo -e "    - ${INST_ID} (${INST_NAME})"
    done
    echo ""
    echo -e "  ${BOLD}Estimated Cost:${NC}"
    echo -e "    Local (${LOCAL_RETENTION}-day): ~\$1-3/mo"
    echo -e "    DR (${DR_RETENTION}-day):    ~\$5-15/mo"
    echo -e "    Total:            ~\$6-18/mo"
    echo ""
    echo -e "  ${BOLD}Verify:${NC}"
    echo -e "    aws backup list-backup-jobs --by-backup-vault-name ${SOURCE_VAULT} --by-resource-type EC2 --region ${SOURCE_REGION}"
    echo -e "    aws backup list-recovery-points-by-backup-vault --backup-vault-name ${SOURCE_VAULT} --region ${SOURCE_REGION}"
    echo -e "    aws backup list-recovery-points-by-backup-vault --backup-vault-name ${DR_VAULT} --region ${DR_REGION}"
    separator
    echo ""
}

###############################################################################
#                             MAIN DISPATCH
###############################################################################
case "$COMMAND" in
    audit)   do_audit ;;
    cleanup) do_cleanup ;;
    create)  do_create ;;
    *)
        echo "Unknown command: $COMMAND"
        echo "Usage: $0 {audit|cleanup|create} [options]"
        exit 1
        ;;
esac
