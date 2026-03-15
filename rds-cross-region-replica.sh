#!/bin/bash
set -euo pipefail

# ============================================================
# RDS Cross-Region Read Replica Setup Script
# ============================================================
# Discovers RDS instances in the source region, displays details,
# and creates cross-region read replicas in the destination region
# for disaster recovery.
#
# Features:
#   - Auto-discovers all RDS instances in source region
#   - Shows detailed info (engine, class, storage, MultiAZ, encryption)
#   - Per-instance confirmation before creating replica
#   - Handles encrypted instances (creates/reuses KMS key in DR region)
#   - Supports MySQL, PostgreSQL, MariaDB, Oracle, SQL Server
#   - --dry-run mode for safe preview
#   - Detects existing replicas and skips them
#
# Usage:
#   ./rds-cross-region-replica.sh [--dry-run]
#
# Environment:
#   SOURCE_REGION  - Source region (default: me-south-1)
#   DEST_REGION    - DR region (default: eu-west-1)
# ============================================================

SOURCE_REGION="${SOURCE_REGION:-me-south-1}"
DEST_REGION="${DEST_REGION:-eu-west-1}"
REPLICA_SUFFIX="${REPLICA_SUFFIX:--dr-replica}"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${CYAN}==>${NC} $*"; }
log_dry()   { echo -e "${YELLOW}[DRY-RUN]${NC} $*"; }

# Safe increment (avoids set -e crash when var is 0)
inc() { eval "$1=\$(( ${!1} + 1 ))"; }

# ── Pre-flight checks ──────────────────────────────────────
command -v aws >/dev/null 2>&1 || { log_error "AWS CLI not found. Install it first."; exit 1; }
command -v jq >/dev/null 2>&1 || { log_error "jq not found. Install it first."; exit 1; }

if $DRY_RUN; then
    echo ""
    log_warn "══════════════════════════════════════"
    log_warn "  DRY-RUN MODE — no changes will be made"
    log_warn "══════════════════════════════════════"
fi

log_step "Detecting AWS identity..."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
log_info "Account : $ACCOUNT_ID"
log_info "Identity: $CALLER_ARN"

# ── Allow overriding regions interactively ──────────────────
read -rp "Source region      [${SOURCE_REGION}]: " input
SOURCE_REGION="${input:-$SOURCE_REGION}"

read -rp "Destination region [${DEST_REGION}]: " input
DEST_REGION="${input:-$DEST_REGION}"

if [[ "$SOURCE_REGION" == "$DEST_REGION" ]]; then
    log_error "Source and destination regions must differ."
    exit 1
fi

# ── Discover RDS instances ──────────────────────────────────
log_step "Discovering RDS instances in ${SOURCE_REGION}..."

RDS_JSON=$(aws rds describe-db-instances \
    --region "$SOURCE_REGION" \
    --query 'DBInstances[?ReadReplicaSourceDBInstanceIdentifier==`null` && DBClusterIdentifier==`null`]' \
    --output json 2>/dev/null || echo "[]")

# Filter out instances that are themselves replicas or Aurora cluster members
DB_COUNT=$(echo "$RDS_JSON" | jq 'length')

if [[ "$DB_COUNT" -eq 0 ]]; then
    log_warn "No primary RDS instances found in ${SOURCE_REGION}."
    exit 0
fi

echo ""
log_info "Found ${DB_COUNT} primary RDS instance(s) in ${SOURCE_REGION}:"
echo ""

# ── Display instance table ──────────────────────────────────
printf "  %-4s %-25s %-18s %-16s %-10s %-10s %-10s %-10s\n" \
    "#" "DB Identifier" "Engine" "Instance Class" "Storage" "MultiAZ" "Encrypted" "Status"
printf "  %-4s %-25s %-18s %-16s %-10s %-10s %-10s %-10s\n" \
    "---" "-------------------------" "------------------" "----------------" "----------" "----------" "----------" "----------"

for i in $(seq 0 $((DB_COUNT - 1))); do
    db_id=$(echo "$RDS_JSON" | jq -r ".[$i].DBInstanceIdentifier")
    engine=$(echo "$RDS_JSON" | jq -r ".[$i].Engine")
    engine_ver=$(echo "$RDS_JSON" | jq -r ".[$i].EngineVersion")
    db_class=$(echo "$RDS_JSON" | jq -r ".[$i].DBInstanceClass")
    storage=$(echo "$RDS_JSON" | jq -r ".[$i].AllocatedStorage")
    multi_az=$(echo "$RDS_JSON" | jq -r ".[$i].MultiAZ")
    encrypted=$(echo "$RDS_JSON" | jq -r ".[$i].StorageEncrypted")
    status=$(echo "$RDS_JSON" | jq -r ".[$i].DBInstanceStatus")

    printf "  %-4s %-25s %-18s %-16s %-10s %-10s %-10s %-10s\n" \
        "$((i+1))" "$db_id" "${engine} ${engine_ver}" "$db_class" "${storage} GB" "$multi_az" "$encrypted" "$status"
done

# ── Instance selection ──────────────────────────────────────
echo ""
read -rp "Enter instance numbers to replicate (comma-separated, or 'all'): " selection

SELECTED_INDICES=()
if [[ "$selection" == "all" ]]; then
    for i in $(seq 0 $((DB_COUNT - 1))); do
        SELECTED_INDICES+=("$i")
    done
else
    IFS=',' read -ra indices <<< "$selection"
    for idx in "${indices[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        if [[ "$idx" -ge 1 && "$idx" -le "$DB_COUNT" ]]; then
            SELECTED_INDICES+=("$((idx - 1))")
        else
            log_warn "Skipping invalid index: $idx"
        fi
    done
fi

if [[ ${#SELECTED_INDICES[@]} -eq 0 ]]; then
    log_error "No valid instances selected."
    exit 1
fi

# ── KMS key setup for encrypted replicas ────────────────────
get_or_create_dr_kms_key() {
    local alias_name="alias/dr-rds-replica-key"

    # Check if key alias already exists in DR region
    local existing_key
    existing_key=$(aws kms describe-key --key-id "$alias_name" \
        --region "$DEST_REGION" --query 'KeyMetadata.Arn' --output text 2>/dev/null || echo "")

    if [[ -n "$existing_key" && "$existing_key" != "None" ]]; then
        log_info "Reusing existing KMS key in ${DEST_REGION}: ${existing_key}" >&2
        echo "$existing_key"
        return
    fi

    if $DRY_RUN; then
        log_dry "Would create KMS key in ${DEST_REGION} with alias ${alias_name}" >&2
        echo "DRY-RUN-KMS-KEY-ARN"
        return
    fi

    log_step "Creating KMS key in ${DEST_REGION} for encrypted replicas..." >&2
    local key_arn
    key_arn=$(aws kms create-key \
        --region "$DEST_REGION" \
        --description "DR RDS replica encryption key for account ${ACCOUNT_ID}" \
        --query 'KeyMetadata.Arn' --output text)

    aws kms create-alias \
        --region "$DEST_REGION" \
        --alias-name "$alias_name" \
        --target-key-id "$key_arn" &>/dev/null

    log_info "Created KMS key: ${key_arn}" >&2
    echo "$key_arn"
}

# ── Check for existing replica ──────────────────────────────
check_existing_replica() {
    local replica_id="$1"
    local status
    status=$(aws rds describe-db-instances \
        --db-instance-identifier "$replica_id" \
        --region "$DEST_REGION" \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null || echo "NOT_FOUND")
    echo "$status"
}

# ── Process each selected instance ──────────────────────────
created=0
skipped=0
failed=0
KMS_KEY_ARN=""

for idx in "${SELECTED_INDICES[@]}"; do
    db_id=$(echo "$RDS_JSON" | jq -r ".[$idx].DBInstanceIdentifier")
    engine=$(echo "$RDS_JSON" | jq -r ".[$idx].Engine")
    engine_ver=$(echo "$RDS_JSON" | jq -r ".[$idx].EngineVersion")
    db_class=$(echo "$RDS_JSON" | jq -r ".[$idx].DBInstanceClass")
    storage=$(echo "$RDS_JSON" | jq -r ".[$idx].AllocatedStorage")
    multi_az=$(echo "$RDS_JSON" | jq -r ".[$idx].MultiAZ")
    encrypted=$(echo "$RDS_JSON" | jq -r ".[$idx].StorageEncrypted")
    status=$(echo "$RDS_JSON" | jq -r ".[$idx].DBInstanceStatus")
    db_arn=$(echo "$RDS_JSON" | jq -r ".[$idx].DBInstanceArn")
    storage_type=$(echo "$RDS_JSON" | jq -r ".[$idx].StorageType")
    iops=$(echo "$RDS_JSON" | jq -r ".[$idx].Iops // empty")
    kms_key=$(echo "$RDS_JSON" | jq -r ".[$idx].KmsKeyId // empty")
    backup_retention=$(echo "$RDS_JSON" | jq -r ".[$idx].BackupRetentionPeriod")
    existing_replicas=$(echo "$RDS_JSON" | jq -r ".[$idx].ReadReplicaDBInstanceIdentifiers | length")
    auto_minor=$(echo "$RDS_JSON" | jq -r ".[$idx].AutoMinorVersionUpgrade")
    param_group=$(echo "$RDS_JSON" | jq -r ".[$idx].DBParameterGroups[0].DBParameterGroupName // empty")

    replica_id="${db_id}${REPLICA_SUFFIX}"

    log_step "Processing: ${db_id} -> ${replica_id}"

    # Check if instance is available
    if [[ "$status" != "available" ]]; then
        log_warn "Instance '${db_id}' is in state '${status}' — skipping."
        inc skipped
        continue
    fi

    # Check backup retention (required for cross-region replicas)
    if [[ "$backup_retention" -eq 0 ]]; then
        log_warn "Instance '${db_id}' has backup retention = 0. Enabling automated backups first..."
        if ! $DRY_RUN; then
            aws rds modify-db-instance \
                --db-instance-identifier "$db_id" \
                --backup-retention-period 7 \
                --region "$SOURCE_REGION" \
                --apply-immediately &>/dev/null
            log_info "Backup retention set to 7 days. Wait a few minutes for first backup, then re-run."
            inc skipped
            continue
        else
            log_dry "Would enable backup retention (7 days) on ${db_id}"
        fi
    fi

    # Check if replica already exists
    replica_status=$(check_existing_replica "$replica_id")
    if [[ "$replica_status" != "NOT_FOUND" ]]; then
        log_warn "Replica '${replica_id}' already exists in ${DEST_REGION} (status: ${replica_status}) — skipping."
        inc skipped
        continue
    fi

    # ── Confirmation prompt ─────────────────────────────────
    echo ""
    echo -e "${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  RDS Cross-Region Read Replica Plan                          ${CYAN}│${NC}"
    echo -e "${CYAN}├──────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  Account        : ${ACCOUNT_ID}"
    echo -e "${CYAN}│${NC}  Source Instance : ${db_id}"
    echo -e "${CYAN}│${NC}  Replica Name    : ${replica_id}"
    echo -e "${CYAN}│${NC}  Source Region   : ${SOURCE_REGION}"
    echo -e "${CYAN}│${NC}  DR Region       : ${DEST_REGION}"
    echo -e "${CYAN}│${NC}  Engine          : ${engine} ${engine_ver}"
    echo -e "${CYAN}│${NC}  Instance Class  : ${db_class}"
    echo -e "${CYAN}│${NC}  Storage         : ${storage} GB (${storage_type}${iops:+, ${iops} IOPS})"
    echo -e "${CYAN}│${NC}  MultiAZ Source  : ${multi_az}"
    echo -e "${CYAN}│${NC}  Encrypted       : ${encrypted}"
    echo -e "${CYAN}│${NC}  Backup Retention: ${backup_retention} days"
    echo -e "${CYAN}│${NC}  Existing Replicas: ${existing_replicas}"
    echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
    echo ""

    if $DRY_RUN; then
        log_dry "Would create read replica '${replica_id}' in ${DEST_REGION}"
        inc created
        continue
    fi

    read -rp "Create read replica '${replica_id}' in ${DEST_REGION}? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_warn "Skipping ${db_id}."
        inc skipped
        continue
    fi

    # ── Resolve KMS key for encrypted instances ─────────────
    replica_kms_arg=""
    if [[ "$encrypted" == "true" ]]; then
        if [[ -z "$KMS_KEY_ARN" ]]; then
            KMS_KEY_ARN=$(get_or_create_dr_kms_key)
        fi
        replica_kms_arg="--kms-key-id ${KMS_KEY_ARN}"
    fi

    # ── Build create-replica command ────────────────────────
    log_step "Creating read replica '${replica_id}' in ${DEST_REGION}..."

    create_cmd=(
        aws rds create-db-instance-read-replica
        --db-instance-identifier "$replica_id"
        --source-db-instance-identifier "$db_arn"
        --db-instance-class "$db_class"
        --region "$DEST_REGION"
        --no-multi-az
        --no-publicly-accessible
        --auto-minor-version-upgrade
        --storage-type "$storage_type"
    )

    # Add IOPS if provisioned
    if [[ -n "$iops" && "$iops" != "null" && "$storage_type" == "io1" ]]; then
        create_cmd+=(--iops "$iops")
    fi

    # Add KMS key for encrypted instances
    if [[ "$encrypted" == "true" && -n "$KMS_KEY_ARN" ]]; then
        create_cmd+=(--kms-key-id "$KMS_KEY_ARN")
    fi

    set +e
    create_output=$("${create_cmd[@]}" 2>&1)
    create_rc=$?
    set -e
    if [[ $create_rc -eq 0 ]]; then
        log_info "Read replica '${replica_id}' creation initiated."
        log_info "  Source : ${db_arn}"
        log_info "  Region : ${DEST_REGION}"
        log_info "  Class  : ${db_class}"
        log_info "  Status : Creating (takes 10-30 minutes)"
        echo ""
        log_info "Monitor progress:"
        echo "  aws rds describe-db-instances --db-instance-identifier ${replica_id} --region ${DEST_REGION} --query 'DBInstances[0].DBInstanceStatus' --output text"
        inc created
    else
        log_error "Failed to create replica '${replica_id}':"
        echo "$create_output"
        inc failed
    fi
done

# ── Summary ─────────────────────────────────────────────────
echo ""
log_step "Summary"
echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
log_info "Created : ${created}"
log_info "Skipped : ${skipped}"
log_info "Failed  : ${failed}"
echo -e "${CYAN}──────────────────────────────────────────────────${NC}"

if [[ $created -gt 0 ]]; then
    echo ""
    log_info "Replicas are being created asynchronously."
    log_info "List all replicas in ${DEST_REGION}:"
    echo "  aws rds describe-db-instances --region ${DEST_REGION} --query 'DBInstances[?ReadReplicaSourceDBInstanceIdentifier!=\`null\`].[DBInstanceIdentifier,DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output table"
    echo ""
    log_info "To promote a replica during DR failover:"
    echo "  aws rds promote-read-replica --db-instance-identifier <replica-id> --region ${DEST_REGION}"
    echo ""
    log_warn "IMPORTANT: Cross-region replicas incur ongoing costs:"
    log_warn "  - Compute: Same as source instance class"
    log_warn "  - Storage: Replicated storage in DR region"
    log_warn "  - Data transfer: Cross-region replication traffic"
fi
