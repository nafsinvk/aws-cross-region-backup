#!/bin/bash
###############################################################################
# DR Create Backup Plan
# Creates an AWS Backup plan with daily backups copied to a DR region
# Local backups are kept for a short retention; DR copies kept longer
#
# Usage: ./dr-create-backup-plan.sh [options]
#   --region SOURCE_REGION        Source region (default: me-south-1)
#   --dr-region DR_REGION         DR region (default: eu-west-1)
#   --plan-name NAME              Backup plan name
#   --instance-ids "i-xxx i-yyy"  Space-separated instance IDs to back up
#   --local-retention DAYS        Local backup retention in days (default: 3)
#   --dr-retention DAYS           DR copy retention in days (default: 30)
#   --schedule CRON               Backup schedule cron (default: daily at 1AM UTC)
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
SCHEDULE="cron(0 1 * * ? *)"  # Daily at 1:00 AM UTC

# ─── Parse Arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)          SOURCE_REGION="$2"; shift 2 ;;
        --dr-region)       DR_REGION="$2"; shift 2 ;;
        --plan-name)       PLAN_NAME="$2"; shift 2 ;;
        --instance-ids)    INSTANCE_IDS="$2"; shift 2 ;;
        --local-retention) LOCAL_RETENTION="$2"; shift 2 ;;
        --dr-retention)    DR_RETENTION="$2"; shift 2 ;;
        --schedule)        SCHEDULE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--region SRC] [--dr-region DR] --plan-name NAME --instance-ids \"i-xxx i-yyy\" [--local-retention DAYS] [--dr-retention DAYS]"
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

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

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

# ─── Validate Inputs ─────────────────────────────────────────────────────────
if [[ -z "$INSTANCE_IDS" ]]; then
    error "Missing --instance-ids. Example: --instance-ids \"i-007b4e0b4f2a0c823 i-076b835c6bc7770e3\""
fi
if [[ -z "$PLAN_NAME" ]]; then
    error "Missing --plan-name. Example: --plan-name \"DailyBackupToIreland\""
fi

# ─── Detect Account ─────────────────────────────────────────────────────────
separator
echo -e "${BOLD}AWS BACKUP PLAN CREATOR${NC}"
echo -e "Creates daily backup with cross-region copy to DR"
separator

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) || {
    error "Failed to get AWS account info. Check your credentials."
}
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "N/A")

echo -e "  Account:         ${BOLD}${ACCOUNT_ID}${NC} (${ACCOUNT_ALIAS})"
echo -e "  Source Region:   ${BOLD}${SOURCE_REGION}${NC}"
echo -e "  DR Region:       ${BOLD}${DR_REGION}${NC}"
echo -e "  Plan Name:       ${BOLD}${PLAN_NAME}${NC}"
echo -e "  Schedule:        ${SCHEDULE} (daily at 1:00 AM UTC)"
echo -e "  Local Retention: ${LOCAL_RETENTION} days (${SOURCE_REGION})"
echo -e "  DR Retention:    ${DR_RETENTION} days (${DR_REGION})"
echo -e "  Date:            $(date '+%Y-%m-%d %H:%M:%S')"

# ─── Validate Instances ─────────────────────────────────────────────────────
separator
echo -e "\n${BOLD}STEP 1: Validate Target Instances${NC}\n"

RESOURCE_ARNS=()
for INST_ID in $INSTANCE_IDS; do
    INST_INFO=$(aws ec2 describe-instances \
        --instance-ids "$INST_ID" \
        --query 'Reservations[0].Instances[0].[State.Name, InstanceType, (Tags[?Key==`Name`].Value)[0]]' \
        --output text --region "$SOURCE_REGION" 2>/dev/null) || {
        error "Instance ${INST_ID} not found in ${SOURCE_REGION}."
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
    error "No instances selected. Exiting."
fi

# ─── Step 2: Ensure Backup Vaults Exist ─────────────────────────────────────
separator
echo -e "\n${BOLD}STEP 2: Ensure Backup Vaults Exist${NC}\n"

# Source region vault
SOURCE_VAULT="Default"
EXISTING_SOURCE=$(aws backup describe-backup-vault \
    --backup-vault-name "$SOURCE_VAULT" \
    --region "$SOURCE_REGION" 2>/dev/null && echo "exists" || echo "")

if [[ -n "$EXISTING_SOURCE" ]]; then
    success "Source vault '${SOURCE_VAULT}' exists in ${SOURCE_REGION}"
else
    info "Creating backup vault '${SOURCE_VAULT}' in ${SOURCE_REGION}..."
    aws backup create-backup-vault \
        --backup-vault-name "$SOURCE_VAULT" \
        --region "$SOURCE_REGION" 2>/dev/null
    success "Created vault '${SOURCE_VAULT}' in ${SOURCE_REGION}"
fi

# DR region vault
DR_VAULT="DR-Backup-Vault"
EXISTING_DR=$(aws backup describe-backup-vault \
    --backup-vault-name "$DR_VAULT" \
    --region "$DR_REGION" 2>/dev/null && echo "exists" || echo "")

if [[ -n "$EXISTING_DR" ]]; then
    success "DR vault '${DR_VAULT}' exists in ${DR_REGION}"
else
    info "Creating backup vault '${DR_VAULT}' in ${DR_REGION}..."
    aws backup create-backup-vault \
        --backup-vault-name "$DR_VAULT" \
        --region "$DR_REGION" 2>/dev/null
    success "Created vault '${DR_VAULT}' in ${DR_REGION}"
fi

DR_VAULT_ARN="arn:aws:backup:${DR_REGION}:${ACCOUNT_ID}:backup-vault:${DR_VAULT}"

# ─── Step 3: Create IAM Role ────────────────────────────────────────────────
separator
echo -e "\n${BOLD}STEP 3: Ensure Backup IAM Role${NC}\n"

ROLE_NAME="AWSBackupServiceRole-${PLAN_NAME}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# Check if role exists
EXISTING_ROLE=$(aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null && echo "exists" || echo "")

if [[ -n "$EXISTING_ROLE" ]]; then
    success "IAM role '${ROLE_NAME}' already exists"
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)
else
    info "Creating IAM role '${ROLE_NAME}'..."

    # Trust policy for AWS Backup
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
        --description "AWS Backup role for ${PLAN_NAME}" 2>/dev/null

    # Attach AWS managed policies for backup
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

# ─── Step 4: Create Backup Plan ─────────────────────────────────────────────
separator
echo -e "\n${BOLD}STEP 4: Create Backup Plan${NC}\n"

# Check if plan with this name already exists
EXISTING_PLAN_ID=$(aws backup list-backup-plans \
    --query "BackupPlansList[?BackupPlanName=='${PLAN_NAME}'].BackupPlanId | [0]" \
    --output text --region "$SOURCE_REGION" 2>/dev/null || echo "None")

if [[ "$EXISTING_PLAN_ID" != "None" && -n "$EXISTING_PLAN_ID" ]]; then
    warn "Backup plan '${PLAN_NAME}' already exists (ID: ${EXISTING_PLAN_ID})."
    if ! confirm "Delete and recreate it?"; then
        info "Keeping existing plan. Exiting."
        exit 0
    fi
    aws backup delete-backup-plan \
        --backup-plan-id "$EXISTING_PLAN_ID" \
        --region "$SOURCE_REGION" 2>/dev/null
    success "Deleted old plan."
fi

# Build the backup plan JSON
BACKUP_PLAN_JSON=$(cat <<EOF
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
EOF
)

info "Creating backup plan '${PLAN_NAME}'..."
PLAN_RESULT=$(aws backup create-backup-plan \
    --backup-plan "$BACKUP_PLAN_JSON" \
    --region "$SOURCE_REGION" \
    --output json 2>/dev/null) || error "Failed to create backup plan."

PLAN_ID=$(echo "$PLAN_RESULT" | jq -r '.BackupPlanId')
PLAN_ARN=$(echo "$PLAN_RESULT" | jq -r '.BackupPlanArn')
success "Created backup plan: ${PLAN_NAME} (${PLAN_ID})"

# ─── Step 5: Create Backup Selection ────────────────────────────────────────
separator
echo -e "\n${BOLD}STEP 5: Assign Instances to Backup Plan${NC}\n"

# Build resource ARN array
RESOURCE_JSON=$(printf '%s\n' "${RESOURCE_ARNS[@]}" | jq -R . | jq -s .)

SELECTION_JSON=$(cat <<EOF
{
    "SelectionName": "${PLAN_NAME}-Selection",
    "IamRoleArn": "${ROLE_ARN}",
    "Resources": ${RESOURCE_JSON}
}
EOF
)

info "Creating backup selection..."
SEL_RESULT=$(aws backup create-backup-selection \
    --backup-plan-id "$PLAN_ID" \
    --backup-selection "$SELECTION_JSON" \
    --region "$SOURCE_REGION" \
    --output json 2>/dev/null) || error "Failed to create backup selection."

SEL_ID=$(echo "$SEL_RESULT" | jq -r '.SelectionId')
success "Created backup selection: ${PLAN_NAME}-Selection (${SEL_ID})"

# ─── Summary ────────────────────────────────────────────────────────────────
separator
echo -e "${BOLD}BACKUP PLAN CREATED SUCCESSFULLY${NC}"
separator
echo ""
echo -e "  ${BOLD}Plan Name:${NC}       ${PLAN_NAME}"
echo -e "  ${BOLD}Plan ID:${NC}         ${PLAN_ID}"
echo -e "  ${BOLD}Selection ID:${NC}    ${SEL_ID}"
echo -e "  ${BOLD}IAM Role:${NC}        ${ROLE_NAME}"
echo ""
echo -e "  ${BOLD}Schedule:${NC}"
echo -e "    Daily at 1:00 AM UTC"
echo ""
echo -e "  ${BOLD}Backup Flow:${NC}"
echo -e "    1. Create backup in ${SOURCE_REGION} (vault: ${SOURCE_VAULT})"
echo -e "    2. Copy to ${DR_REGION} (vault: ${DR_VAULT})"
echo -e "    3. Delete local copy after ${LOCAL_RETENTION} days"
echo -e "    4. Delete DR copy after ${DR_RETENTION} days"
echo ""
echo -e "  ${BOLD}Protected Instances:${NC}"
for INST_ID in $INSTANCE_IDS; do
    INST_NAME=$(aws ec2 describe-instances \
        --instance-ids "$INST_ID" \
        --query 'Reservations[0].Instances[0].Tags[?Key==`Name`].Value | [0]' \
        --output text --region "$SOURCE_REGION" 2>/dev/null || echo "unnamed")
    echo -e "    - ${INST_ID} (${INST_NAME})"
done
echo ""
echo -e "  ${BOLD}Estimated Cost:${NC}"
echo -e "    Local snapshots (${LOCAL_RETENTION}-day retention): ~\$1-3/mo"
echo -e "    DR copies in ${DR_REGION} (${DR_RETENTION}-day retention): ~\$5-15/mo"
echo -e "    Total: ~\$6-18/mo (depends on EBS volume sizes)"
separator
echo ""
echo -e "  To verify: ${CYAN}aws backup list-backup-jobs --by-backup-plan-id ${PLAN_ID} --region ${SOURCE_REGION}${NC}"
echo -e "  To check DR vault: ${CYAN}aws backup list-recovery-points-by-backup-vault --backup-vault-name ${DR_VAULT} --region ${DR_REGION}${NC}"
echo ""
