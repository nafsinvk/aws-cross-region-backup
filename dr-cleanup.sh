#!/bin/bash
###############################################################################
# DR Cleanup Script
# Stops wasteful AWS Backup on stopped EC2 instances & releases unattached EIPs
# Usage: ./dr-cleanup.sh [--region REGION]
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

# ─── Helper Functions ────────────────────────────────────────────────────────
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
echo -e "${BOLD}AWS DR CLEANUP SCRIPT${NC}"
separator

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) || {
    error "Failed to get AWS account info. Check your credentials."
    exit 1
}
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "N/A")
CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)

echo -e "  Account:  ${BOLD}${ACCOUNT_ID}${NC} (${ACCOUNT_ALIAS})"
echo -e "  Region:   ${BOLD}${REGION}${NC}"
echo -e "  Identity: ${CALLER_ARN}"
echo -e "  Date:     $(date '+%Y-%m-%d %H:%M:%S')"
separator

BACKUP_CLEANED=0
BACKUP_SKIPPED=0
EIP_RELEASED=0
EIP_SKIPPED=0

###############################################################################
# SECTION 1: AWS Backup on Stopped Instances
###############################################################################
echo -e "\n${BOLD}SECTION 1: AWS Backup Plans Backing Up Stopped EC2 Instances${NC}\n"

# Step 1: Get all stopped EC2 instance IDs
info "Fetching stopped EC2 instances..."
STOPPED_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text --region "$REGION" 2>/dev/null || echo "")

if [[ -z "$STOPPED_INSTANCES" ]]; then
    info "No stopped EC2 instances found. Skipping backup cleanup."
else
    STOPPED_COUNT=$(echo "$STOPPED_INSTANCES" | wc -w | tr -d ' ')
    info "Found ${STOPPED_COUNT} stopped instance(s)."

    # Step 2: Get all backup plans
    info "Fetching AWS Backup plans..."
    BACKUP_PLANS_JSON=$(aws backup list-backup-plans \
        --query 'BackupPlansList[].{Id:BackupPlanId,Name:BackupPlanName}' \
        --output json --region "$REGION" 2>/dev/null || echo "[]")

    PLAN_COUNT=$(echo "$BACKUP_PLANS_JSON" | jq length)

    if [[ "$PLAN_COUNT" -eq 0 ]]; then
        info "No AWS Backup plans found in this account/region."
    else
        info "Found ${PLAN_COUNT} backup plan(s). Checking selections..."

        # Step 3: For each backup plan, check selections for stopped instances
        for PLAN_IDX in $(seq 0 $((PLAN_COUNT - 1))); do
            PLAN_ID=$(echo "$BACKUP_PLANS_JSON" | jq -r ".[$PLAN_IDX].Id")
            PLAN_NAME=$(echo "$BACKUP_PLANS_JSON" | jq -r ".[$PLAN_IDX].Name")

            # Get selections for this plan
            SELECTIONS_JSON=$(aws backup list-backup-selections \
                --backup-plan-id "$PLAN_ID" \
                --query 'BackupSelectionsList[].{Id:SelectionId,Name:SelectionName}' \
                --output json --region "$REGION" 2>/dev/null || echo "[]")

            SEL_COUNT=$(echo "$SELECTIONS_JSON" | jq length)

            for SEL_IDX in $(seq 0 $((SEL_COUNT - 1))); do
                SEL_ID=$(echo "$SELECTIONS_JSON" | jq -r ".[$SEL_IDX].Id")
                SEL_NAME=$(echo "$SELECTIONS_JSON" | jq -r ".[$SEL_IDX].Name")

                # Get the full selection detail to see resources
                SELECTION_DETAIL=$(aws backup get-backup-selection \
                    --backup-plan-id "$PLAN_ID" \
                    --selection-id "$SEL_ID" \
                    --output json --region "$REGION" 2>/dev/null || echo "{}")

                # Extract resource ARNs from the selection
                RESOURCE_ARNS=$(echo "$SELECTION_DETAIL" | jq -r '.BackupSelection.Resources[]? // empty' 2>/dev/null || echo "")

                # Check if selection uses tag-based or wildcard ("*") matching
                HAS_WILDCARD=$(echo "$SELECTION_DETAIL" | jq -r '.BackupSelection.Resources[]? // empty' | grep -c '^\*$' || true)
                LIST_OF_TAGS=$(echo "$SELECTION_DETAIL" | jq -r '.BackupSelection.ListOfTags // empty' 2>/dev/null || echo "")
                CONDITIONS=$(echo "$SELECTION_DETAIL" | jq -r '.BackupSelection.Conditions // empty' 2>/dev/null || echo "")

                # Case 1: Selection targets specific instance ARNs
                if [[ -n "$RESOURCE_ARNS" && "$HAS_WILDCARD" -eq 0 ]]; then
                    for INST_ID in $STOPPED_INSTANCES; do
                        if echo "$RESOURCE_ARNS" | grep -q "$INST_ID"; then
                            # Get instance name
                            INST_NAME=$(aws ec2 describe-instances \
                                --instance-ids "$INST_ID" \
                                --query 'Reservations[0].Instances[0].Tags[?Key==`Name`].Value | [0]' \
                                --output text --region "$REGION" 2>/dev/null || echo "unnamed")

                            echo ""
                            warn "WASTEFUL BACKUP FOUND:"
                            echo -e "    Backup Plan:  ${BOLD}${PLAN_NAME}${NC} (${PLAN_ID})"
                            echo -e "    Selection:    ${SEL_NAME} (${SEL_ID})"
                            echo -e "    Instance:     ${BOLD}${INST_ID}${NC} (${INST_NAME})"
                            echo -e "    Status:       ${RED}STOPPED${NC} - backups are creating identical snapshots daily"

                            # Count existing recovery points for this resource
                            RP_COUNT=$(aws backup list-recovery-points-by-resource \
                                --resource-arn "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/${INST_ID}" \
                                --query 'length(RecoveryPoints)' \
                                --output text --region "$REGION" 2>/dev/null || echo "unknown")
                            echo -e "    Recovery Points: ${RP_COUNT}"

                            # Check how many resources in this selection
                            RESOURCE_COUNT=$(echo "$RESOURCE_ARNS" | wc -l | tr -d ' ')

                            if [[ "$RESOURCE_COUNT" -eq 1 ]]; then
                                # Only resource in selection - can delete the whole selection
                                if confirm "    Delete backup selection '${SEL_NAME}' (only targets this stopped instance)?"; then
                                    aws backup delete-backup-selection \
                                        --backup-plan-id "$PLAN_ID" \
                                        --selection-id "$SEL_ID" \
                                        --region "$REGION" 2>/dev/null && \
                                        success "Deleted backup selection '${SEL_NAME}'" || \
                                        error "Failed to delete backup selection"
                                    ((BACKUP_CLEANED++))
                                else
                                    info "Skipped."
                                    ((BACKUP_SKIPPED++))
                                fi
                            else
                                # Multiple resources - need to recreate selection without this instance
                                echo -e "    ${YELLOW}NOTE: This selection targets ${RESOURCE_COUNT} resources.${NC}"
                                echo -e "    Removing this instance requires recreating the selection without it."

                                if confirm "    Remove instance ${INST_ID} from backup selection '${SEL_NAME}'?"; then
                                    # Build new resource list excluding this instance
                                    NEW_RESOURCES=$(echo "$RESOURCE_ARNS" | grep -v "$INST_ID" | jq -R -s 'split("\n") | map(select(length > 0))')
                                    IAM_ROLE=$(echo "$SELECTION_DETAIL" | jq -r '.BackupSelection.IamRoleArn')

                                    # Build new selection JSON
                                    NEW_SELECTION=$(echo "$SELECTION_DETAIL" | jq --argjson res "$NEW_RESOURCES" \
                                        '.BackupSelection.Resources = $res | .BackupSelection')

                                    # Delete old selection
                                    aws backup delete-backup-selection \
                                        --backup-plan-id "$PLAN_ID" \
                                        --selection-id "$SEL_ID" \
                                        --region "$REGION" 2>/dev/null

                                    # Create new selection without the stopped instance
                                    aws backup create-backup-selection \
                                        --backup-plan-id "$PLAN_ID" \
                                        --backup-selection "$NEW_SELECTION" \
                                        --region "$REGION" 2>/dev/null && \
                                        success "Removed ${INST_ID} from backup selection. Selection recreated." || \
                                        error "Failed to recreate backup selection. Manual fix needed!"
                                    ((BACKUP_CLEANED++))
                                else
                                    info "Skipped."
                                    ((BACKUP_SKIPPED++))
                                fi
                            fi
                        fi
                    done
                fi

                # Case 2: Selection uses wildcard (*) or tag-based matching
                if [[ "$HAS_WILDCARD" -gt 0 ]] || [[ -n "$LIST_OF_TAGS" && "$LIST_OF_TAGS" != "null" && "$LIST_OF_TAGS" != "" ]]; then
                    # Check if any stopped instances match this selection by checking recovery points
                    FOUND_MATCH=false
                    for INST_ID in $STOPPED_INSTANCES; do
                        RP_COUNT=$(aws backup list-recovery-points-by-resource \
                            --resource-arn "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/${INST_ID}" \
                            --query 'length(RecoveryPoints)' \
                            --output text --region "$REGION" 2>/dev/null || echo "0")

                        if [[ "$RP_COUNT" -gt 0 && "$RP_COUNT" != "0" ]]; then
                            INST_NAME=$(aws ec2 describe-instances \
                                --instance-ids "$INST_ID" \
                                --query 'Reservations[0].Instances[0].Tags[?Key==`Name`].Value | [0]' \
                                --output text --region "$REGION" 2>/dev/null || echo "unnamed")

                            if [[ "$FOUND_MATCH" == false ]]; then
                                echo ""
                                warn "TAG/WILDCARD-BASED BACKUP PLAN INCLUDES STOPPED INSTANCES:"
                                echo -e "    Backup Plan:  ${BOLD}${PLAN_NAME}${NC} (${PLAN_ID})"
                                echo -e "    Selection:    ${SEL_NAME} (${SEL_ID})"
                                if [[ "$HAS_WILDCARD" -gt 0 ]]; then
                                    echo -e "    Match Type:   ${YELLOW}Wildcard (*)${NC} - backs up ALL EC2 instances"
                                else
                                    echo -e "    Match Type:   ${YELLOW}Tag-based${NC}"
                                fi
                                echo ""
                                echo -e "    Stopped instances with recovery points from this plan:"
                                FOUND_MATCH=true
                            fi
                            echo -e "      - ${INST_ID} (${INST_NAME}) - ${RP_COUNT} recovery points"
                        fi
                    done

                    if [[ "$FOUND_MATCH" == true ]]; then
                        echo ""
                        echo -e "    ${YELLOW}RECOMMENDATION: Since this is a wildcard/tag-based selection, you cannot${NC}"
                        echo -e "    ${YELLOW}remove individual instances. Options:${NC}"
                        echo -e "    ${YELLOW}  1. Add an exclusion tag to stopped instances${NC}"
                        echo -e "    ${YELLOW}  2. Switch to resource-based selection (list specific ARNs)${NC}"
                        echo -e "    ${YELLOW}  3. Stop the instances from matching by removing the tag${NC}"
                        echo ""

                        if confirm "    Add tag 'backup-exclude=true' to ALL stopped instances (for manual exclusion setup)?"; then
                            for INST_ID in $STOPPED_INSTANCES; do
                                aws ec2 create-tags \
                                    --resources "$INST_ID" \
                                    --tags "Key=backup-exclude,Value=true" \
                                    --region "$REGION" 2>/dev/null && \
                                    success "Tagged ${INST_ID} with backup-exclude=true" || \
                                    error "Failed to tag ${INST_ID}"
                            done
                            echo ""
                            warn "Tags added. You must manually update the backup selection to exclude"
                            warn "instances with tag 'backup-exclude=true' via the AWS Console or CLI."
                            ((BACKUP_CLEANED++))
                        else
                            info "Skipped."
                            ((BACKUP_SKIPPED++))
                        fi
                    fi
                fi
            done
        done
    fi
fi

###############################################################################
# SECTION 2: Unattached Elastic IPs
###############################################################################
separator
echo -e "\n${BOLD}SECTION 2: Unattached Elastic IPs${NC}\n"

info "Fetching Elastic IPs..."

# Get all EIPs - unattached ones have no AssociationId
EIPS_JSON=$(aws ec2 describe-addresses \
    --query 'Addresses[?AssociationId==null || AssociationId==`""`]' \
    --output json --region "$REGION" 2>/dev/null || echo "[]")

# Also get EIPs attached to stopped instances
EIPS_STOPPED_JSON="[]"
if [[ -n "${STOPPED_INSTANCES:-}" ]]; then
    ALL_EIPS=$(aws ec2 describe-addresses --output json --region "$REGION" 2>/dev/null || echo '{"Addresses":[]}')
    for INST_ID in $STOPPED_INSTANCES; do
        MATCHED=$(echo "$ALL_EIPS" | jq --arg id "$INST_ID" '[.Addresses[] | select(.InstanceId == $id)]')
        if [[ $(echo "$MATCHED" | jq length) -gt 0 ]]; then
            EIPS_STOPPED_JSON=$(echo "$EIPS_STOPPED_JSON $MATCHED" | jq -s 'add')
        fi
    done
fi

EIP_UNATTACHED_COUNT=$(echo "$EIPS_JSON" | jq length)
EIP_STOPPED_COUNT=$(echo "$EIPS_STOPPED_JSON" | jq length)
TOTAL_EIP_WASTE=$((EIP_UNATTACHED_COUNT + EIP_STOPPED_COUNT))

if [[ "$TOTAL_EIP_WASTE" -eq 0 ]]; then
    info "No unattached or wasted Elastic IPs found."
else
    # Part A: Fully unattached EIPs
    if [[ "$EIP_UNATTACHED_COUNT" -gt 0 ]]; then
        echo -e "  ${YELLOW}Found ${EIP_UNATTACHED_COUNT} unattached Elastic IP(s) (~\$${EIP_UNATTACHED_COUNT} x \$3.65/mo = \$$(echo "$EIP_UNATTACHED_COUNT * 3.65" | bc | sed 's/\.00$//')/mo waste):${NC}"
        echo ""

        for IDX in $(seq 0 $((EIP_UNATTACHED_COUNT - 1))); do
            ALLOC_ID=$(echo "$EIPS_JSON" | jq -r ".[$IDX].AllocationId")
            PUBLIC_IP=$(echo "$EIPS_JSON" | jq -r ".[$IDX].PublicIp")
            DOMAIN=$(echo "$EIPS_JSON" | jq -r ".[$IDX].Domain // \"vpc\"")
            TAGS=$(echo "$EIPS_JSON" | jq -r ".[$IDX].Tags // [] | map(\"\(.Key)=\(.Value)\") | join(\", \")")

            echo -e "    ${BOLD}Elastic IP: ${PUBLIC_IP}${NC}"
            echo -e "      Allocation ID: ${ALLOC_ID}"
            echo -e "      Domain:        ${DOMAIN}"
            echo -e "      Tags:          ${TAGS:-none}"
            echo -e "      Status:        ${RED}UNATTACHED${NC} (~\$3.65/mo waste)"

            if confirm "      Release this Elastic IP (${PUBLIC_IP})?"; then
                aws ec2 release-address \
                    --allocation-id "$ALLOC_ID" \
                    --region "$REGION" 2>/dev/null && \
                    success "Released ${PUBLIC_IP} (${ALLOC_ID})" || \
                    error "Failed to release ${PUBLIC_IP}"
                ((EIP_RELEASED++))
            else
                info "Skipped ${PUBLIC_IP}."
                ((EIP_SKIPPED++))
            fi
            echo ""
        done
    fi

    # Part B: EIPs attached to stopped instances
    if [[ "$EIP_STOPPED_COUNT" -gt 0 ]]; then
        echo -e "  ${YELLOW}Found ${EIP_STOPPED_COUNT} Elastic IP(s) attached to STOPPED instances (~\$3.65/mo each):${NC}"
        echo ""

        for IDX in $(seq 0 $((EIP_STOPPED_COUNT - 1))); do
            ALLOC_ID=$(echo "$EIPS_STOPPED_JSON" | jq -r ".[$IDX].AllocationId")
            ASSOC_ID=$(echo "$EIPS_STOPPED_JSON" | jq -r ".[$IDX].AssociationId")
            PUBLIC_IP=$(echo "$EIPS_STOPPED_JSON" | jq -r ".[$IDX].PublicIp")
            INST_ID=$(echo "$EIPS_STOPPED_JSON" | jq -r ".[$IDX].InstanceId")
            TAGS=$(echo "$EIPS_STOPPED_JSON" | jq -r ".[$IDX].Tags // [] | map(\"\(.Key)=\(.Value)\") | join(\", \")")

            INST_NAME=$(aws ec2 describe-instances \
                --instance-ids "$INST_ID" \
                --query 'Reservations[0].Instances[0].Tags[?Key==`Name`].Value | [0]' \
                --output text --region "$REGION" 2>/dev/null || echo "unnamed")

            echo -e "    ${BOLD}Elastic IP: ${PUBLIC_IP}${NC}"
            echo -e "      Allocation ID:  ${ALLOC_ID}"
            echo -e "      Association ID: ${ASSOC_ID}"
            echo -e "      Attached to:    ${INST_ID} (${INST_NAME})"
            echo -e "      Instance State: ${RED}STOPPED${NC} (~\$3.65/mo waste)"
            echo -e "      Tags:           ${TAGS:-none}"

            if confirm "      Disassociate and release this Elastic IP (${PUBLIC_IP})?"; then
                # First disassociate
                aws ec2 disassociate-address \
                    --association-id "$ASSOC_ID" \
                    --region "$REGION" 2>/dev/null && \
                    success "Disassociated ${PUBLIC_IP} from ${INST_ID}" || \
                    { error "Failed to disassociate ${PUBLIC_IP}"; continue; }

                # Then release
                if confirm "      Also release the IP (${PUBLIC_IP})? (Say 'n' to keep it unattached)"; then
                    aws ec2 release-address \
                        --allocation-id "$ALLOC_ID" \
                        --region "$REGION" 2>/dev/null && \
                        success "Released ${PUBLIC_IP}" || \
                        error "Failed to release ${PUBLIC_IP}"
                    ((EIP_RELEASED++))
                else
                    info "EIP disassociated but kept. It is now unattached (still costs \$3.65/mo)."
                    ((EIP_RELEASED++))
                fi
            else
                info "Skipped ${PUBLIC_IP}."
                ((EIP_SKIPPED++))
            fi
            echo ""
        done
    fi
fi

###############################################################################
# SUMMARY
###############################################################################
separator
echo -e "${BOLD}CLEANUP SUMMARY${NC}"
separator
echo -e "  Account:  ${ACCOUNT_ID} (${ACCOUNT_ALIAS})"
echo -e "  Region:   ${REGION}"
echo ""
echo -e "  ${BOLD}AWS Backup:${NC}"
echo -e "    Cleaned:  ${GREEN}${BACKUP_CLEANED}${NC}"
echo -e "    Skipped:  ${YELLOW}${BACKUP_SKIPPED}${NC}"
echo ""
echo -e "  ${BOLD}Elastic IPs:${NC}"
echo -e "    Released: ${GREEN}${EIP_RELEASED}${NC}"
echo -e "    Skipped:  ${YELLOW}${EIP_SKIPPED}${NC}"
echo ""

TOTAL_SAVINGS=$(echo "($BACKUP_CLEANED * 10) + ($EIP_RELEASED * 3.65)" | bc 2>/dev/null || echo "N/A")
echo -e "  ${BOLD}Estimated Monthly Savings: ~\$${TOTAL_SAVINGS}${NC}"
separator
echo ""
