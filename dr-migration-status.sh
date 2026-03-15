#!/bin/bash
set -euo pipefail

# ============================================================
# AWS DR Migration Status Script
# ============================================================
# Scans source and DR regions to determine the current state
# of disaster recovery migration for the current account.
#
# Checks:
#   1. AWS Backup plans (existence, DR copy rules, recovery points)
#   2. DR Backup Vault in DR region (existence, recovery points)
#   3. S3 Cross-Region Replication (per-bucket CRR status)
#   4. RDS Cross-Region Read Replicas
#   5. ECR Cross-Region Replication
#   6. EC2 instances backup coverage
#   7. Route 53 / DNS failover readiness
#   8. ACM certificates in DR region
#
# Usage:
#   ./dr-migration-status.sh
#   ./dr-migration-status.sh --region me-south-1 --dr-region eu-west-1
# ============================================================

SOURCE_REGION="${SOURCE_REGION:-me-south-1}"
DEST_REGION="${DEST_REGION:-eu-west-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "\n${CYAN}==>${NC} ${BOLD}$*${NC}"; }
divider()     { echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"; }
status_ok()   { echo -e "    ${GREEN}✓${NC} $*"; }
status_warn() { echo -e "    ${YELLOW}⚠${NC} $*"; }
status_fail() { echo -e "    ${RED}✗${NC} $*"; }
status_skip() { echo -e "    ${CYAN}–${NC} $*"; }

# Safe increment (avoids set -e crash when var is 0)
inc() { eval "$1=\$(( ${!1} + 1 ))"; }

# ── Pre-flight checks ──────────────────────────────────────
command -v aws >/dev/null 2>&1 || { log_error "AWS CLI not found."; exit 1; }
command -v jq >/dev/null 2>&1  || { log_error "jq not found."; exit 1; }

# ── Parse arguments ────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)       SOURCE_REGION="$2"; shift 2 ;;
        --dr-region)    DEST_REGION="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--region SOURCE_REGION] [--dr-region DR_REGION]"
            echo "  --region     Source region (default: me-south-1)"
            echo "  --dr-region  DR region (default: eu-west-1)"
            exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

echo ""
divider
echo -e "${BOLD}  AWS DR MIGRATION STATUS${NC}"
divider

log_step "Detecting AWS identity..."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "")
if [[ -z "$ACCOUNT_ALIAS" || "$ACCOUNT_ALIAS" == "None" ]]; then
    ACCOUNT_ALIAS=$(aws organizations describe-account --account-id "$ACCOUNT_ID" \
        --query 'Account.Name' --output text 2>/dev/null || echo "")
fi
ACCOUNT_LABEL="${ACCOUNT_ALIAS:-$ACCOUNT_ID}"
[[ -z "$ACCOUNT_ALIAS" || "$ACCOUNT_ALIAS" == "None" ]] && ACCOUNT_ALIAS=""

log_info "Account : $ACCOUNT_ID ($ACCOUNT_LABEL)"
log_info "Identity: $CALLER_ARN"
log_info "Source  : $SOURCE_REGION"
log_info "DR      : $DEST_REGION"

# Build report filename
REPORT_FILE="dr-status-${ACCOUNT_ID}"
[[ -n "$ACCOUNT_ALIAS" ]] && REPORT_FILE="${REPORT_FILE}-${ACCOUNT_ALIAS// /-}"
REPORT_FILE="${REPORT_FILE}-$(date +%Y%m%d-%H%M%S).txt"

# Tee all output to both terminal and report file
exec > >(tee -a "$REPORT_FILE") 2>&1

divider

# Scoreboard
total_checks=0
passed_checks=0
warn_checks=0
fail_checks=0

record_pass() { inc total_checks; inc passed_checks; }
record_warn() { inc total_checks; inc warn_checks; }
record_fail() { inc total_checks; inc fail_checks; }

# ════════════════════════════════════════════════════════════
# 1. EC2 INSTANCE BACKUP COVERAGE
# ════════════════════════════════════════════════════════════
log_step "1. EC2 INSTANCE BACKUP COVERAGE"

echo -e "\n  ${BOLD}Running Instances:${NC}"
RUNNING_INSTANCES=$(aws ec2 describe-instances --region "$SOURCE_REGION" \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")

RUNNING_COUNT=0
RUNNING_IDS=()
if [[ -n "$RUNNING_INSTANCES" && "$RUNNING_INSTANCES" != "None" ]]; then
    while IFS=$'\t' read -r iid itype name; do
        echo "    - $iid | $itype | ${name:-N/A}"
        RUNNING_IDS+=("$iid")
        inc RUNNING_COUNT
    done <<< "$RUNNING_INSTANCES"
    echo "    Total: $RUNNING_COUNT running instance(s)"
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Stopped Instances:${NC}"
STOPPED_INSTANCES=$(aws ec2 describe-instances --region "$SOURCE_REGION" \
    --filters "Name=instance-state-name,Values=stopped" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==`Name`].Value|[0],Tags[?Key==`backup-exclude`].Value|[0]]' \
    --output text 2>/dev/null || echo "")

STOPPED_COUNT=0
STOPPED_TAGGED=0
if [[ -n "$STOPPED_INSTANCES" && "$STOPPED_INSTANCES" != "None" ]]; then
    while IFS=$'\t' read -r iid itype name exclude_tag; do
        local_tag=""
        if [[ "$exclude_tag" == "true" ]]; then
            local_tag=" [backup-exclude]"
            inc STOPPED_TAGGED
        fi
        echo "    - $iid | $itype | ${name:-N/A}${local_tag}"
        inc STOPPED_COUNT
    done <<< "$STOPPED_INSTANCES"
    echo "    Total: $STOPPED_COUNT stopped instance(s), $STOPPED_TAGGED tagged backup-exclude"
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 2. AWS BACKUP PLANS
# ════════════════════════════════════════════════════════════
log_step "2. AWS BACKUP PLANS"

BACKUP_PLANS=$(aws backup list-backup-plans --region "$SOURCE_REGION" \
    --query 'BackupPlansList[].[BackupPlanId,BackupPlanName,CreationDate]' \
    --output text 2>/dev/null || echo "")

PLAN_COUNT=0
PLANS_WITH_DR=0
PLANS_ORPHANED=0
BACKED_UP_INSTANCE_IDS=()

if [[ -n "$BACKUP_PLANS" && "$BACKUP_PLANS" != "None" ]]; then
    while IFS=$'\t' read -r plan_id plan_name created; do
        inc PLAN_COUNT
        echo -e "\n  ${BOLD}Plan: ${plan_name}${NC} (${plan_id})"
        echo "    Created: $created"

        # Check rules for DR copy
        plan_json=$(aws backup get-backup-plan --backup-plan-id "$plan_id" --region "$SOURCE_REGION" 2>/dev/null || echo "")
        has_dr_copy=false
        if [[ -n "$plan_json" ]]; then
            rule_count=$(echo "$plan_json" | jq '.BackupPlan.Rules | length' 2>/dev/null || echo "0")
            for (( r=0; r<rule_count; r++ )); do
                rule_name=$(echo "$plan_json" | jq -r ".BackupPlan.Rules[$r].RuleName" 2>/dev/null || echo "N/A")
                schedule=$(echo "$plan_json" | jq -r ".BackupPlan.Rules[$r].ScheduleExpression // \"N/A\"" 2>/dev/null || echo "N/A")
                lifecycle_days=$(echo "$plan_json" | jq -r ".BackupPlan.Rules[$r].Lifecycle.DeleteAfterDays // \"N/A\"" 2>/dev/null || echo "N/A")
                copy_actions=$(echo "$plan_json" | jq ".BackupPlan.Rules[$r].CopyActions // [] | length" 2>/dev/null || echo "0")

                echo "    Rule: $rule_name | Schedule: $schedule | Retention: ${lifecycle_days} days"

                if [[ "$copy_actions" -gt 0 ]]; then
                    for (( c=0; c<copy_actions; c++ )); do
                        copy_dest=$(echo "$plan_json" | jq -r ".BackupPlan.Rules[$r].CopyActions[$c].DestinationBackupVaultArn" 2>/dev/null || echo "N/A")
                        copy_retention=$(echo "$plan_json" | jq -r ".BackupPlan.Rules[$r].CopyActions[$c].Lifecycle.DeleteAfterDays // \"N/A\"" 2>/dev/null || echo "N/A")
                        if echo "$copy_dest" | grep -q "$DEST_REGION"; then
                            has_dr_copy=true
                            status_ok "DR copy to $DEST_REGION (retention: ${copy_retention} days)"
                        else
                            echo "    Copy: $copy_dest (retention: ${copy_retention} days)"
                        fi
                    done
                fi
            done
        fi

        if $has_dr_copy; then
            inc PLANS_WITH_DR
        else
            status_warn "No DR copy action to $DEST_REGION"
        fi

        # Check selections
        selections=$(aws backup list-backup-selections --backup-plan-id "$plan_id" --region "$SOURCE_REGION" \
            --query 'BackupSelectionsList[].[SelectionId,SelectionName]' --output text 2>/dev/null || echo "")

        if [[ -z "$selections" || "$selections" == "None" ]]; then
            status_fail "ORPHANED — No selections (backing up nothing)"
            inc PLANS_ORPHANED
        else
            while IFS=$'\t' read -r sel_id sel_name; do
                sel_json=$(aws backup get-backup-selection --backup-plan-id "$plan_id" \
                    --selection-id "$sel_id" --region "$SOURCE_REGION" 2>/dev/null || echo "")

                if [[ -n "$sel_json" ]]; then
                    # Collect instance ARNs from the selection
                    resource_arns=$(echo "$sel_json" | jq -r '.BackupSelection.Resources[]? // empty' 2>/dev/null || echo "")
                    if [[ -n "$resource_arns" ]]; then
                        for arn in $resource_arns; do
                            # Extract instance ID from ARN
                            if echo "$arn" | grep -q "instance/"; then
                                inst_id=$(echo "$arn" | grep -oP 'instance/\K[^ ]+' 2>/dev/null || echo "$arn" | awk -F'instance/' '{print $2}')
                                BACKED_UP_INSTANCE_IDS+=("$inst_id")
                                echo "    Protected: $inst_id"
                            else
                                echo "    Resource: $arn"
                            fi
                        done
                    fi

                    # Check for tag-based selection
                    tag_conditions=$(echo "$sel_json" | jq '.BackupSelection.ListOfTags // [] | length' 2>/dev/null || echo "0")
                    if [[ "$tag_conditions" -gt 0 ]]; then
                        echo "    Selection: Tag-based ($tag_conditions condition(s))"
                    fi
                fi
            done <<< "$selections"
        fi
    done <<< "$BACKUP_PLANS"

    echo ""
    if [[ $PLAN_COUNT -gt 0 ]]; then
        status_ok "Backup plans found: $PLAN_COUNT"
        record_pass
    fi
    if [[ $PLANS_WITH_DR -gt 0 ]]; then
        status_ok "Plans with DR copy: $PLANS_WITH_DR"
        record_pass
    else
        status_fail "No plans have DR copy to $DEST_REGION"
        record_fail
    fi
    if [[ $PLANS_ORPHANED -gt 0 ]]; then
        status_warn "Orphaned plans (0 selections): $PLANS_ORPHANED — run: ./scripts/dr-backup-manager.sh cleanup"
        record_warn
    fi
else
    echo "    (no backup plans found)"
    if [[ $RUNNING_COUNT -gt 0 ]]; then
        status_fail "No backup plans — $RUNNING_COUNT running instances are UNPROTECTED"
        record_fail
    else
        status_skip "No backup plans (no running instances either)"
    fi
fi

# Coverage: which running instances are backed up?
echo -e "\n  ${BOLD}Backup Coverage:${NC}"
covered=0
uncovered=0
uncovered_list=()
for iid in "${RUNNING_IDS[@]+"${RUNNING_IDS[@]}"}"; do
    found=false
    for bid in "${BACKED_UP_INSTANCE_IDS[@]+"${BACKED_UP_INSTANCE_IDS[@]}"}"; do
        if [[ "$iid" == "$bid" ]]; then
            found=true
            break
        fi
    done
    if $found; then
        inc covered
    else
        inc uncovered
        uncovered_list+=("$iid")
    fi
done

if [[ $RUNNING_COUNT -gt 0 ]]; then
    echo "    Covered: $covered / $RUNNING_COUNT running instances"
    if [[ $uncovered -gt 0 ]]; then
        status_warn "$uncovered running instance(s) NOT covered by any backup plan:"
        for uid in "${uncovered_list[@]+"${uncovered_list[@]}"}"; do
            # Look up name
            uname=$(aws ec2 describe-instances --region "$SOURCE_REGION" --instance-ids "$uid" \
                --query 'Reservations[0].Instances[0].Tags[?Key==`Name`].Value|[0]' --output text 2>/dev/null || echo "N/A")
            echo "      - $uid ($uname)"
        done
        record_warn
    else
        status_ok "All running instances are covered by backup plans"
        record_pass
    fi
else
    status_skip "No running instances to check"
fi

# ════════════════════════════════════════════════════════════
# 3. DR BACKUP VAULT (eu-west-1)
# ════════════════════════════════════════════════════════════
log_step "3. DR BACKUP VAULT ($DEST_REGION)"

DR_VAULT_NAME="DR-Backup-Vault"
DR_VAULT=$(aws backup describe-backup-vault --backup-vault-name "$DR_VAULT_NAME" \
    --region "$DEST_REGION" 2>/dev/null || echo "")

if [[ -n "$DR_VAULT" ]]; then
    rp_count=$(echo "$DR_VAULT" | jq -r '.NumberOfRecoveryPoints // 0' 2>/dev/null || echo "0")
    vault_created=$(echo "$DR_VAULT" | jq -r '.CreationDate // "N/A"' 2>/dev/null || echo "N/A")
    status_ok "DR vault '$DR_VAULT_NAME' exists in $DEST_REGION (created: $vault_created)"
    echo "    Recovery points: $rp_count"
    record_pass

    if [[ "$rp_count" -gt 0 ]]; then
        status_ok "DR vault has $rp_count recovery point(s)"
        record_pass

        # Show latest recovery points
        echo -e "\n  ${BOLD}Latest Recovery Points:${NC}"
        latest_rps=$(aws backup list-recovery-points-by-backup-vault \
            --backup-vault-name "$DR_VAULT_NAME" --region "$DEST_REGION" \
            --query 'RecoveryPoints | sort_by(@, &CreationDate) | [-5:].[RecoveryPointArn,ResourceType,CreationDate,Status]' \
            --output text 2>/dev/null || echo "")
        if [[ -n "$latest_rps" && "$latest_rps" != "None" ]]; then
            while IFS=$'\t' read -r rp_arn rtype rp_created rp_status; do
                rp_short=$(echo "$rp_arn" | awk -F: '{print $NF}')
                echo "    - $rp_short | $rtype | $rp_created | $rp_status"
            done <<< "$latest_rps"
        fi
    else
        status_warn "DR vault exists but has 0 recovery points — backups may not have run yet"
        record_warn
    fi
else
    status_fail "DR vault '$DR_VAULT_NAME' NOT found in $DEST_REGION"
    record_fail
fi

# Also check Default vault in source region
echo -e "\n  ${BOLD}Source Vault (Default, $SOURCE_REGION):${NC}"
SRC_VAULT=$(aws backup describe-backup-vault --backup-vault-name "Default" \
    --region "$SOURCE_REGION" 2>/dev/null || echo "")
if [[ -n "$SRC_VAULT" ]]; then
    src_rp_count=$(echo "$SRC_VAULT" | jq -r '.NumberOfRecoveryPoints // 0' 2>/dev/null || echo "0")
    status_ok "Default vault: $src_rp_count recovery point(s)"
else
    status_skip "No Default vault in $SOURCE_REGION"
fi

# ════════════════════════════════════════════════════════════
# 4. S3 CROSS-REGION REPLICATION
# ════════════════════════════════════════════════════════════
log_step "4. S3 CROSS-REGION REPLICATION"

ALL_BUCKETS=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null || echo "")
MY_CANONICAL_ID=$(aws s3api list-buckets --query 'Owner.ID' --output text 2>/dev/null || echo "")

s3_total=0
s3_replicated=0
s3_versioned=0
s3_no_replication=0
s3_cross_account=0

if [[ -n "$ALL_BUCKETS" ]]; then
    for bucket in $ALL_BUCKETS; do
        region=$(aws s3api get-bucket-location --bucket "$bucket" \
            --query 'LocationConstraint' --output text 2>/dev/null || true)
        [[ "$region" == "None" ]] && region="us-east-1"
        if [[ "$region" != "$SOURCE_REGION" ]]; then
            continue
        fi

        inc s3_total

        # Check ownership
        bucket_owner=$(aws s3api get-bucket-acl --bucket "$bucket" \
            --query 'Owner.ID' --output text 2>/dev/null || echo "UNKNOWN")
        if [[ -n "$MY_CANONICAL_ID" && "$bucket_owner" != "UNKNOWN" && "$bucket_owner" != "$MY_CANONICAL_ID" ]]; then
            status_skip "$bucket — cross-account bucket (not ours)"
            inc s3_cross_account
            continue
        fi

        versioning=$(aws s3api get-bucket-versioning --bucket "$bucket" \
            --query 'Status' --output text 2>/dev/null || echo "None")
        [[ "$versioning" == "Enabled" ]] && inc s3_versioned

        repl_status=$(aws s3api get-bucket-replication --bucket "$bucket" \
            --query 'ReplicationConfiguration.Rules[0].Status' --output text 2>/dev/null || echo "None")
        repl_dest=$(aws s3api get-bucket-replication --bucket "$bucket" \
            --query 'ReplicationConfiguration.Rules[0].Destination.Bucket' --output text 2>/dev/null || echo "None")

        # Check if backup bucket exists in DR region
        dest_bucket_name="${bucket}-backup"
        dest_bucket_exists=false
        if aws s3api head-bucket --bucket "$dest_bucket_name" &>/dev/null; then
            dest_bucket_exists=true
        elif aws s3api head-bucket --bucket "${dest_bucket_name}-${ACCOUNT_ID}" &>/dev/null; then
            dest_bucket_name="${dest_bucket_name}-${ACCOUNT_ID}"
            dest_bucket_exists=true
        fi

        if [[ "$repl_status" == "Enabled" ]]; then
            status_ok "$bucket → $repl_dest (replication: Enabled, versioning: $versioning)"
            inc s3_replicated
        elif $dest_bucket_exists; then
            status_warn "$bucket → $dest_bucket_name (synced, no active replication, versioning: $versioning)"
            inc s3_no_replication
        else
            status_fail "$bucket (no replication, no backup bucket, versioning: $versioning)"
            inc s3_no_replication
        fi
    done

    echo ""
    echo "    Buckets in $SOURCE_REGION: $s3_total (+ $s3_cross_account cross-account)"
    echo "    Replicated (CRR active): $s3_replicated"
    echo "    Versioning enabled: $s3_versioned"
    echo "    No replication: $s3_no_replication"

    if [[ $s3_total -gt 0 ]]; then
        if [[ $s3_replicated -eq $((s3_total - s3_cross_account)) && $s3_replicated -gt 0 ]]; then
            status_ok "All own buckets have CRR enabled"
            record_pass
        elif [[ $s3_replicated -gt 0 ]]; then
            status_warn "$s3_replicated of $((s3_total - s3_cross_account)) own buckets have CRR"
            record_warn
        else
            status_fail "No S3 buckets have cross-region replication"
            record_fail
        fi
    fi
else
    echo "    (no S3 buckets)"
fi

# ════════════════════════════════════════════════════════════
# 5. RDS CROSS-REGION READ REPLICAS
# ════════════════════════════════════════════════════════════
log_step "5. RDS CROSS-REGION READ REPLICAS"

# Source RDS instances (primary only, filter out replicas and Aurora)
echo -e "\n  ${BOLD}Source RDS Instances ($SOURCE_REGION):${NC}"
SRC_RDS=$(aws rds describe-db-instances --region "$SOURCE_REGION" \
    --query 'DBInstances[?ReadReplicaSourceDBInstanceIdentifier==`null` && DBClusterIdentifier==`null`].[DBInstanceIdentifier,Engine,EngineVersion,DBInstanceClass,AllocatedStorage,MultiAZ,StorageEncrypted,DBInstanceStatus]' \
    --output text 2>/dev/null || echo "")

rds_total=0
rds_replicated=0
rds_no_replica=0
RDS_IDS=()

if [[ -n "$SRC_RDS" && "$SRC_RDS" != "None" ]]; then
    while IFS=$'\t' read -r dbid engine ver dbclass storage multiaz encrypted status; do
        echo "    - $dbid | $engine $ver | $dbclass | ${storage}GB | MultiAZ: $multiaz | Encrypted: $encrypted | $status"
        RDS_IDS+=("$dbid")
        inc rds_total
    done <<< "$SRC_RDS"
else
    echo "    (none)"
fi

# Check for replicas in DR region
echo -e "\n  ${BOLD}DR Read Replicas ($DEST_REGION):${NC}"
DR_RDS=$(aws rds describe-db-instances --region "$DEST_REGION" \
    --query 'DBInstances[?ReadReplicaSourceDBInstanceIdentifier!=`null`].[DBInstanceIdentifier,ReadReplicaSourceDBInstanceIdentifier,DBInstanceStatus,Engine,EngineVersion,DBInstanceClass,AllocatedStorage]' \
    --output text 2>/dev/null || echo "")

DR_REPLICA_SOURCES=()
if [[ -n "$DR_RDS" && "$DR_RDS" != "None" ]]; then
    while IFS=$'\t' read -r replica_id source_id rep_status engine ver dbclass storage; do
        # Extract source instance name from ARN or direct name
        source_name=$(echo "$source_id" | awk -F: '{print $NF}')
        echo "    - $replica_id | Source: $source_name | $engine $ver | $dbclass | ${storage}GB | $rep_status"
        DR_REPLICA_SOURCES+=("$source_name")
        if [[ "$rep_status" == "available" ]]; then
            status_ok "$replica_id is available"
            inc rds_replicated
        else
            status_warn "$replica_id status: $rep_status"
        fi
    done <<< "$DR_RDS"
else
    echo "    (none)"
fi

# Match source RDS to replicas
echo -e "\n  ${BOLD}RDS DR Coverage:${NC}"
for dbid in "${RDS_IDS[@]+"${RDS_IDS[@]}"}"; do
    found=false
    for src in "${DR_REPLICA_SOURCES[@]+"${DR_REPLICA_SOURCES[@]}"}"; do
        if [[ "$src" == "$dbid" || "$src" == *":db:$dbid" ]]; then
            found=true
            break
        fi
    done
    if $found; then
        status_ok "$dbid — has cross-region read replica in $DEST_REGION"
    else
        status_fail "$dbid — NO cross-region read replica"
        inc rds_no_replica
    fi
done

if [[ $rds_total -gt 0 ]]; then
    echo "    RDS instances: $rds_total | With DR replica: $rds_replicated | Missing: $rds_no_replica"
    if [[ $rds_no_replica -eq 0 && $rds_total -gt 0 ]]; then
        status_ok "All RDS instances have DR replicas"
        record_pass
    elif [[ $rds_replicated -gt 0 ]]; then
        status_warn "$rds_replicated of $rds_total RDS instances have DR replicas"
        record_warn
    else
        status_fail "No RDS instances have DR replicas"
        record_fail
    fi
else
    status_skip "No primary RDS instances in $SOURCE_REGION"
fi

# ════════════════════════════════════════════════════════════
# 6. ECS / ECR CROSS-REGION REPLICATION
# ════════════════════════════════════════════════════════════
log_step "6. ECS / ECR REPLICATION"

echo -e "\n  ${BOLD}ECR Repositories ($SOURCE_REGION):${NC}"
ECR_REPOS=$(aws ecr describe-repositories --region "$SOURCE_REGION" \
    --query 'repositories[].[repositoryName]' \
    --output text 2>/dev/null || echo "")

ecr_count=0
if [[ -n "$ECR_REPOS" && "$ECR_REPOS" != "None" ]]; then
    for repo in $ECR_REPOS; do
        echo "    - $repo"
        inc ecr_count
    done
fi

echo -e "\n  ${BOLD}ECR Replication Configuration:${NC}"
ECR_REPL=$(aws ecr describe-registry --region "$SOURCE_REGION" \
    --query 'replicationConfiguration.rules' 2>/dev/null || echo "[]")

ecr_repl_to_dr=false
if [[ -n "$ECR_REPL" && "$ECR_REPL" != "[]" && "$ECR_REPL" != "null" ]]; then
    repl_dests=$(echo "$ECR_REPL" | jq -r '.[].destinations[]?.region // empty' 2>/dev/null || echo "")
    for dest in $repl_dests; do
        if [[ "$dest" == "$DEST_REGION" ]]; then
            ecr_repl_to_dr=true
            status_ok "ECR replication to $DEST_REGION is configured"
        else
            echo "    Replicating to: $dest"
        fi
    done
fi

if [[ $ecr_count -gt 0 ]]; then
    if $ecr_repl_to_dr; then
        record_pass
    else
        status_warn "ECR has $ecr_count repositories but no replication to $DEST_REGION"
        record_warn
    fi
else
    status_skip "No ECR repositories in $SOURCE_REGION"
fi

echo -e "\n  ${BOLD}ECS Clusters ($SOURCE_REGION):${NC}"
ECS_CLUSTERS=$(aws ecs list-clusters --region "$SOURCE_REGION" \
    --query 'clusterArns[]' --output text 2>/dev/null || echo "")

if [[ -n "$ECS_CLUSTERS" && "$ECS_CLUSTERS" != "None" ]]; then
    for cluster_arn in $ECS_CLUSTERS; do
        cluster_name=$(echo "$cluster_arn" | awk -F/ '{print $NF}')
        svc_count=$(aws ecs list-services --region "$SOURCE_REGION" --cluster "$cluster_name" \
            --query 'serviceArns' --output text 2>/dev/null | wc -w | tr -d ' ')
        echo "    - $cluster_name | Services: $svc_count"
    done
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 7. DR REGION INFRASTRUCTURE
# ════════════════════════════════════════════════════════════
log_step "7. DR REGION INFRASTRUCTURE ($DEST_REGION)"

echo -e "\n  ${BOLD}VPCs in DR Region:${NC}"
DR_VPCS=$(aws ec2 describe-vpcs --region "$DEST_REGION" \
    --query 'Vpcs[].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0],IsDefault]' \
    --output text 2>/dev/null || echo "")

dr_vpc_count=0
if [[ -n "$DR_VPCS" && "$DR_VPCS" != "None" ]]; then
    while IFS=$'\t' read -r vid cidr vname is_default; do
        echo "    - $vid | $cidr | ${vname:-N/A} | Default: $is_default"
        inc dr_vpc_count
    done <<< "$DR_VPCS"
    # Only default VPC = no DR networking set up yet
    non_default_vpcs=$(echo "$DR_VPCS" | grep -c "False" || true)
    if [[ "$non_default_vpcs" -gt 0 ]]; then
        status_ok "Custom VPC(s) found in $DEST_REGION ($non_default_vpcs)"
        record_pass
    else
        status_warn "Only default VPC in $DEST_REGION — DR networking not set up"
        record_warn
    fi
else
    status_fail "No VPCs in $DEST_REGION"
    record_fail
fi

echo -e "\n  ${BOLD}EC2 Instances in DR Region:${NC}"
DR_EC2=$(aws ec2 describe-instances --region "$DEST_REGION" \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$DR_EC2" && "$DR_EC2" != "None" ]]; then
    while IFS=$'\t' read -r iid itype state name; do
        echo "    - $iid | $itype | $state | ${name:-N/A}"
    done <<< "$DR_EC2"
else
    echo "    (none — expected for standby DR)"
fi

echo -e "\n  ${BOLD}Load Balancers in DR Region:${NC}"
DR_LBS=$(aws elbv2 describe-load-balancers --region "$DEST_REGION" \
    --query 'LoadBalancers[].[LoadBalancerName,Type,State.Code]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$DR_LBS" && "$DR_LBS" != "None" ]]; then
    while IFS=$'\t' read -r lbname lbtype state; do
        echo "    - $lbname | $lbtype | $state"
    done <<< "$DR_LBS"
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 8. ACM CERTIFICATES IN DR REGION
# ════════════════════════════════════════════════════════════
log_step "8. ACM CERTIFICATES"

echo -e "\n  ${BOLD}Source Region ($SOURCE_REGION):${NC}"
SRC_CERTS=$(aws acm list-certificates --region "$SOURCE_REGION" \
    --query 'CertificateSummaryList[].[DomainName,Status]' \
    --output text 2>/dev/null || echo "")
src_cert_count=0
SRC_CERT_DOMAINS=()
if [[ -n "$SRC_CERTS" && "$SRC_CERTS" != "None" ]]; then
    while IFS=$'\t' read -r domain status; do
        echo "    - $domain | $status"
        SRC_CERT_DOMAINS+=("$domain")
        inc src_cert_count
    done <<< "$SRC_CERTS"
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}DR Region ($DEST_REGION):${NC}"
DR_CERTS=$(aws acm list-certificates --region "$DEST_REGION" \
    --query 'CertificateSummaryList[].[DomainName,Status]' \
    --output text 2>/dev/null || echo "")
dr_cert_count=0
DR_CERT_DOMAINS=()
if [[ -n "$DR_CERTS" && "$DR_CERTS" != "None" ]]; then
    while IFS=$'\t' read -r domain status; do
        echo "    - $domain | $status"
        DR_CERT_DOMAINS+=("$domain")
        inc dr_cert_count
    done <<< "$DR_CERTS"
else
    echo "    (none)"
fi

echo ""
if [[ $src_cert_count -gt 0 ]]; then
    # Check which source domains have certs in DR
    missing_certs=0
    for src_domain in "${SRC_CERT_DOMAINS[@]}"; do
        found=false
        for dr_domain in "${DR_CERT_DOMAINS[@]+"${DR_CERT_DOMAINS[@]}"}"; do
            if [[ "$src_domain" == "$dr_domain" ]]; then
                found=true
                break
            fi
        done
        if ! $found; then
            status_warn "Certificate for '$src_domain' missing in $DEST_REGION"
            inc missing_certs
        fi
    done

    if [[ $missing_certs -eq 0 ]]; then
        status_ok "All $src_cert_count source certificates have matching DR certificates"
        record_pass
    else
        status_warn "$missing_certs of $src_cert_count certificates missing in $DEST_REGION"
        record_warn
    fi
else
    status_skip "No ACM certificates in source region"
fi

# ════════════════════════════════════════════════════════════
# 9. ROUTE 53 DNS
# ════════════════════════════════════════════════════════════
log_step "9. ROUTE 53 DNS"

HOSTED_ZONES=$(aws route53 list-hosted-zones \
    --query 'HostedZones[].[Id,Name,Config.PrivateZone,ResourceRecordSetCount]' \
    --output text 2>/dev/null || echo "")

r53_zones=0
r53_failover=0
if [[ -n "$HOSTED_ZONES" && "$HOSTED_ZONES" != "None" ]]; then
    while IFS=$'\t' read -r zone_id zone_name is_private rr_count; do
        inc r53_zones
        zone_id_short=$(echo "$zone_id" | awk -F/ '{print $NF}')
        echo "    - $zone_name | Records: $rr_count | Private: $is_private"

        # Check for failover records
        failover_records=$(aws route53 list-resource-record-sets \
            --hosted-zone-id "$zone_id_short" \
            --query 'ResourceRecordSets[?Failover!=`null`].[Name,Type,Failover,SetIdentifier]' \
            --output text 2>/dev/null || echo "")
        if [[ -n "$failover_records" && "$failover_records" != "None" ]]; then
            while IFS=$'\t' read -r rr_name rr_type rr_failover rr_setid; do
                echo "      Failover: $rr_name | $rr_type | $rr_failover | SetID: $rr_setid"
                inc r53_failover
            done <<< "$failover_records"
        fi

        # Check for health checks associated
        health_records=$(aws route53 list-resource-record-sets \
            --hosted-zone-id "$zone_id_short" \
            --query 'ResourceRecordSets[?HealthCheckId!=`null`].[Name,Type,HealthCheckId]' \
            --output text 2>/dev/null || echo "")
        if [[ -n "$health_records" && "$health_records" != "None" ]]; then
            while IFS=$'\t' read -r rr_name rr_type hc_id; do
                echo "      Health-checked: $rr_name | $rr_type | HC: $hc_id"
            done <<< "$health_records"
        fi
    done <<< "$HOSTED_ZONES"

    echo ""
    echo "    Hosted zones: $r53_zones | Failover records: $r53_failover"
    if [[ $r53_failover -gt 0 ]]; then
        status_ok "DNS failover routing is configured ($r53_failover records)"
        record_pass
    else
        status_warn "No DNS failover routing configured (Phase 6 of DR plan)"
        record_warn
    fi
else
    echo "    (no hosted zones found — may need Route 53 permissions)"
fi

# ════════════════════════════════════════════════════════════
# 10. KMS KEYS IN DR REGION
# ════════════════════════════════════════════════════════════
log_step "10. KMS KEYS IN DR REGION ($DEST_REGION)"

DR_KMS_KEYS=$(aws kms list-keys --region "$DEST_REGION" \
    --query 'Keys[].KeyId' --output text 2>/dev/null || echo "")

dr_kms_customer=0
if [[ -n "$DR_KMS_KEYS" && "$DR_KMS_KEYS" != "None" ]]; then
    for kid in $DR_KMS_KEYS; do
        key_info=$(aws kms describe-key --region "$DEST_REGION" --key-id "$kid" \
            --query 'KeyMetadata.[KeyId,KeyState,KeyManager,Description]' \
            --output text 2>/dev/null || echo "")
        IFS=$'\t' read -r keyid state manager desc <<< "$key_info"
        if [[ "$manager" == "CUSTOMER" && "$state" == "Enabled" ]]; then
            # Check aliases
            alias_name=$(aws kms list-aliases --region "$DEST_REGION" --key-id "$kid" \
                --query 'Aliases[0].AliasName' --output text 2>/dev/null || echo "N/A")
            echo "    - $keyid | $alias_name | ${desc:-No description}"
            inc dr_kms_customer
        fi
    done
    echo "    Customer-managed keys: $dr_kms_customer"
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# MIGRATION SCORE & SUMMARY
# ════════════════════════════════════════════════════════════
echo ""
echo ""
divider
echo -e "${BOLD}  DR MIGRATION SUMMARY${NC}"
echo -e "${BOLD}  Account: ${ACCOUNT_ID} (${ACCOUNT_LABEL})${NC}"
echo -e "${BOLD}  Source : ${SOURCE_REGION} → DR: ${DEST_REGION}${NC}"
divider

echo ""
echo -e "  ${BOLD}Resources:${NC}"
echo "    Running EC2 instances    : $RUNNING_COUNT"
echo "    Stopped EC2 instances    : $STOPPED_COUNT (tagged: $STOPPED_TAGGED)"
echo "    S3 buckets (source)      : $s3_total"
echo "    RDS instances (primary)  : $rds_total"
echo "    ECR repositories         : $ecr_count"
echo "    ACM certificates (source): $src_cert_count"
echo "    Route 53 hosted zones    : $r53_zones"

echo ""
echo -e "  ${BOLD}DR Status:${NC}"

# Backup plan status
if [[ $PLANS_WITH_DR -gt 0 ]]; then
    status_ok "EC2 Backup Plans: $PLANS_WITH_DR plan(s) with DR copy"
else
    if [[ $RUNNING_COUNT -gt 0 ]]; then
        status_fail "EC2 Backup Plans: None with DR copy"
    else
        status_skip "EC2 Backup Plans: N/A (no running instances)"
    fi
fi

# DR vault
if [[ -n "$DR_VAULT" ]]; then
    status_ok "DR Backup Vault: $rp_count recovery points"
else
    status_fail "DR Backup Vault: Not created"
fi

# S3
if [[ $s3_replicated -gt 0 ]]; then
    status_ok "S3 Replication: $s3_replicated of $((s3_total - s3_cross_account)) buckets"
elif [[ $s3_total -gt 0 ]]; then
    status_fail "S3 Replication: Not configured"
else
    status_skip "S3 Replication: N/A"
fi

# RDS
if [[ $rds_replicated -gt 0 ]]; then
    status_ok "RDS Replicas: $rds_replicated of $rds_total in $DEST_REGION"
elif [[ $rds_total -gt 0 ]]; then
    status_fail "RDS Replicas: Not created"
else
    status_skip "RDS Replicas: N/A (no RDS)"
fi

# ECR
if $ecr_repl_to_dr; then
    status_ok "ECR Replication: Configured"
elif [[ $ecr_count -gt 0 ]]; then
    status_warn "ECR Replication: Not configured"
else
    status_skip "ECR Replication: N/A"
fi

# DNS
if [[ $r53_failover -gt 0 ]]; then
    status_ok "DNS Failover: $r53_failover record(s)"
else
    status_warn "DNS Failover: Not configured"
fi

# ACM
if [[ $src_cert_count -gt 0 && $dr_cert_count -ge $src_cert_count ]]; then
    status_ok "ACM Certificates: $dr_cert_count in $DEST_REGION"
elif [[ $src_cert_count -gt 0 ]]; then
    status_warn "ACM Certificates: $dr_cert_count of $src_cert_count in $DEST_REGION"
else
    status_skip "ACM Certificates: N/A"
fi

# Overall score
echo ""
echo -e "  ${BOLD}Checks:${NC}"
echo -e "    ${GREEN}Passed${NC} : $passed_checks"
echo -e "    ${YELLOW}Warning${NC}: $warn_checks"
echo -e "    ${RED}Failed${NC} : $fail_checks"
echo -e "    Total  : $total_checks"

if [[ $total_checks -gt 0 ]]; then
    pct=$(( (passed_checks * 100) / total_checks ))
    echo ""
    if [[ $pct -ge 80 ]]; then
        echo -e "  ${GREEN}${BOLD}DR Migration Score: ${pct}%${NC}"
    elif [[ $pct -ge 50 ]]; then
        echo -e "  ${YELLOW}${BOLD}DR Migration Score: ${pct}%${NC}"
    else
        echo -e "  ${RED}${BOLD}DR Migration Score: ${pct}%${NC}"
    fi
fi

# Recommended actions
if [[ $fail_checks -gt 0 || $warn_checks -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}Recommended Actions:${NC}"

    if [[ $PLAN_COUNT -eq 0 && $RUNNING_COUNT -gt 0 ]]; then
        echo "    1. Create EC2 backup plan:"
        echo "       ./scripts/dr-backup-manager.sh create --plan-name \"<Name>\" --instance-ids \"<ids>\""
    fi
    if [[ $PLANS_WITH_DR -eq 0 && $PLAN_COUNT -gt 0 ]]; then
        echo "    - Existing backup plans lack DR copy — recreate with DR copy to $DEST_REGION"
    fi
    if [[ $PLANS_ORPHANED -gt 0 ]]; then
        echo "    - Clean up orphaned backup plans: ./scripts/dr-backup-manager.sh cleanup"
    fi
    if [[ $s3_no_replication -gt 0 ]]; then
        echo "    - Set up S3 CRR: ./scripts/s3-cross-region-backup.sh"
    fi
    if [[ $rds_no_replica -gt 0 ]]; then
        echo "    - Create RDS replicas: ./scripts/rds-cross-region-replica.sh"
    fi
    if [[ $r53_failover -eq 0 && $r53_zones -gt 0 ]]; then
        echo "    - Configure DNS failover routing in Route 53 (Phase 6)"
    fi
    if [[ $src_cert_count -gt 0 && $dr_cert_count -lt $src_cert_count ]]; then
        echo "    - Request ACM certificates in $DEST_REGION for DR domains"
    fi
fi

divider
echo ""
log_info "Report saved to: ${REPORT_FILE}"
echo ""
