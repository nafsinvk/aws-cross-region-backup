#!/bin/bash
set -euo pipefail

# ============================================================
# S3 Cross-Region Backup & Replication Setup Script
# ============================================================
# Discovers S3 buckets in the source region, creates backup
# buckets in the destination region, copies configuration &
# data (sync), and sets up replication rules for ongoing DR.
#
# Features:
#   - Auto-discovers buckets in source region
#   - Bucket ownership check (skips cross-account buckets)
#   - Handles BucketAlreadyExists (falls back to account-suffixed name)
#   - Copies: versioning, encryption, Block Public Access, policy,
#     tags (filters aws:* system tags), lifecycle rules
#   - Syncs existing objects via aws s3 sync
#   - Sets up S3 replication for ongoing changes
#   - Graceful fallback when versioning/replication fails (cross-account)
#   - Per-bucket confirmation
#
# Usage:
#   ./s3-cross-region-backup.sh
#
# Environment:
#   SOURCE_REGION  - Source region (default: me-south-1)
#   DEST_REGION    - DR region (default: eu-west-1)
#   BACKUP_SUFFIX  - Suffix for backup buckets (default: -backup)
# ============================================================

SOURCE_REGION="${SOURCE_REGION:-me-south-1}"
DEST_REGION="${DEST_REGION:-eu-west-1}"
BACKUP_SUFFIX="${BACKUP_SUFFIX:--backup}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${CYAN}==>${NC} $*"; }

# Safe increment (avoids set -e crash when var is 0)
inc() { eval "$1=\$(( ${!1} + 1 ))"; }

# ── Pre-flight checks ──────────────────────────────────────
command -v aws >/dev/null 2>&1 || { log_error "AWS CLI not found. Install it first."; exit 1; }
command -v jq >/dev/null 2>&1 || { log_error "jq not found. Install it first."; exit 1; }

log_step "Detecting AWS identity..."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
log_info "Account : $ACCOUNT_ID"
log_info "Identity: $CALLER_ARN"

# Get canonical ID once for ownership checks
MY_CANONICAL_ID=$(aws s3api list-buckets --query 'Owner.ID' --output text 2>/dev/null || echo "")

# ── Allow overriding regions interactively ──────────────────
read -rp "Source region      [${SOURCE_REGION}]: " input
SOURCE_REGION="${input:-$SOURCE_REGION}"

read -rp "Destination region [${DEST_REGION}]: " input
DEST_REGION="${input:-$DEST_REGION}"

if [[ "$SOURCE_REGION" == "$DEST_REGION" ]]; then
    log_error "Source and destination regions must differ."
    exit 1
fi

# ── List buckets in the source region ───────────────────────
log_step "Listing S3 buckets in region ${SOURCE_REGION}..."
ALL_BUCKETS=$(aws s3api list-buckets --query 'Buckets[].Name' --output text)

SOURCE_BUCKETS=()
for bucket in $ALL_BUCKETS; do
    region=$(aws s3api get-bucket-location --bucket "$bucket" --query 'LocationConstraint' --output text 2>/dev/null || true)
    # us-east-1 returns "None"
    [[ "$region" == "None" ]] && region="us-east-1"
    if [[ "$region" == "$SOURCE_REGION" ]]; then
        SOURCE_BUCKETS+=("$bucket")
    fi
done

if [[ ${#SOURCE_BUCKETS[@]} -eq 0 ]]; then
    log_warn "No buckets found in region ${SOURCE_REGION}."
    exit 0
fi

echo ""
log_info "Found ${#SOURCE_BUCKETS[@]} bucket(s) in ${SOURCE_REGION}:"
for i in "${!SOURCE_BUCKETS[@]}"; do
    echo "  $((i+1)). ${SOURCE_BUCKETS[$i]}"
done

# ── Bucket selection ────────────────────────────────────────
echo ""
read -rp "Enter bucket numbers to replicate (comma-separated, or 'all'): " selection

SELECTED_BUCKETS=()
if [[ "$selection" == "all" ]]; then
    SELECTED_BUCKETS=("${SOURCE_BUCKETS[@]}")
else
    IFS=',' read -ra indices <<< "$selection"
    for idx in "${indices[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        if [[ "$idx" -ge 1 && "$idx" -le ${#SOURCE_BUCKETS[@]} ]]; then
            SELECTED_BUCKETS+=("${SOURCE_BUCKETS[$((idx-1))]}")
        else
            log_warn "Skipping invalid index: $idx"
        fi
    done
fi

if [[ ${#SELECTED_BUCKETS[@]} -eq 0 ]]; then
    log_error "No valid buckets selected."
    exit 1
fi

# ── IAM role for replication ────────────────────────────────
create_replication_role() {
    local role_name="s3-replication-role-${ACCOUNT_ID}"

    if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
        log_info "Replication IAM role already exists: $role_name"
    else
        log_step "Creating IAM replication role: $role_name"
        aws iam create-role \
            --role-name "$role_name" \
            --assume-role-policy-document '{
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": { "Service": "s3.amazonaws.com" },
                    "Action": "sts:AssumeRole"
                }]
            }' --output text >/dev/null
    fi

    # Use a compact wildcard-based policy to stay within the 6144 byte limit
    local policy_doc
    policy_doc=$(cat <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetReplicationConfiguration",
                "s3:ListBucket"
            ],
            "Resource": "arn:aws:s3:::*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObjectVersionForReplication",
                "s3:GetObjectVersionAcl",
                "s3:GetObjectVersionTagging"
            ],
            "Resource": "arn:aws:s3:::*/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:ReplicateObject",
                "s3:ReplicateDelete",
                "s3:ReplicateTags"
            ],
            "Resource": "arn:aws:s3:::*${BACKUP_SUFFIX}/*"
        }
    ]
}
POLICY
)

    local policy_name="s3-replication-policy-${ACCOUNT_ID}"
    local policy_arn="arn:aws:iam::${ACCOUNT_ID}:policy/${policy_name}"

    if aws iam get-policy --policy-arn "$policy_arn" >/dev/null 2>&1; then
        # Update existing policy — create new version and delete oldest if at limit
        local versions
        versions=$(aws iam list-policy-versions --policy-arn "$policy_arn" \
            --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
        for v in $versions; do
            aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$v" 2>/dev/null || true
        done
        aws iam create-policy-version --policy-arn "$policy_arn" \
            --policy-document "$policy_doc" --set-as-default >/dev/null
        log_info "Updated replication policy: $policy_name"
    else
        aws iam create-policy --policy-name "$policy_name" \
            --policy-document "$policy_doc" >/dev/null
        log_info "Created replication policy: $policy_name"
    fi

    aws iam attach-role-policy --role-name "$role_name" \
        --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${policy_name}" 2>/dev/null || true

    REPLICATION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${role_name}"
}

# ── Resolve destination bucket name ─────────────────────────
# Checks if bucket exists (ours or globally taken), creates if needed.
# Sets RESOLVED_DEST_BUCKET and DEST_BUCKET_EXISTED variables.
resolve_dest_bucket() {
    local dest_bucket="$1"
    RESOLVED_DEST_BUCKET=""
    DEST_BUCKET_EXISTED=false

    # Check if we already own this bucket
    if aws s3api head-bucket --bucket "$dest_bucket" 2>/dev/null; then
        local dest_region_check
        dest_region_check=$(aws s3api get-bucket-location --bucket "$dest_bucket" \
            --query 'LocationConstraint' --output text 2>/dev/null || echo "")
        [[ "$dest_region_check" == "None" ]] && dest_region_check="us-east-1"

        if [[ "$dest_region_check" == "$DEST_REGION" ]]; then
            log_info "Bucket '${dest_bucket}' already exists in ${DEST_REGION}." >&2
            RESOLVED_DEST_BUCKET="$dest_bucket"
            DEST_BUCKET_EXISTED=true
            return 0
        else
            log_warn "Bucket '${dest_bucket}' exists but in region '${dest_region_check}', not '${DEST_REGION}'." >&2
            return 1
        fi
    fi

    # Try to create the bucket
    set +e
    local create_output
    create_output=$(aws s3api create-bucket --bucket "$dest_bucket" \
        --region "$DEST_REGION" \
        --create-bucket-configuration LocationConstraint="$DEST_REGION" 2>&1)
    local create_rc=$?
    set -e

    if [[ $create_rc -eq 0 ]]; then
        log_info "Created bucket: ${dest_bucket}" >&2
        RESOLVED_DEST_BUCKET="$dest_bucket"
        return 0
    fi

    # BucketAlreadyExists — name taken globally by another account
    if echo "$create_output" | grep -q "BucketAlreadyExists\|BucketAlreadyOwnedByYou"; then
        log_warn "Bucket name '${dest_bucket}' is already taken globally." >&2
        local alt_bucket="${dest_bucket}-${ACCOUNT_ID}"
        log_info "Trying alternative name: ${alt_bucket}" >&2

        if aws s3api head-bucket --bucket "$alt_bucket" 2>/dev/null; then
            log_info "Bucket '${alt_bucket}' already exists (ours)." >&2
            RESOLVED_DEST_BUCKET="$alt_bucket"
            DEST_BUCKET_EXISTED=true
            return 0
        fi

        set +e
        create_output=$(aws s3api create-bucket --bucket "$alt_bucket" \
            --region "$DEST_REGION" \
            --create-bucket-configuration LocationConstraint="$DEST_REGION" 2>&1)
        create_rc=$?
        set -e

        if [[ $create_rc -eq 0 ]]; then
            log_info "Created bucket: ${alt_bucket}" >&2
            RESOLVED_DEST_BUCKET="$alt_bucket"
            return 0
        else
            log_error "Failed to create alternative bucket '${alt_bucket}':" >&2
            echo "$create_output" >&2
            return 1
        fi
    else
        log_error "Failed to create bucket '${dest_bucket}':" >&2
        echo "$create_output" >&2
        return 1
    fi
}

# ── Process each selected bucket ────────────────────────────
process_bucket() {
    local src_bucket="$1"
    local dest_bucket_base="${src_bucket}${BACKUP_SUFFIX}"

    log_step "Processing: ${src_bucket} -> ${dest_bucket_base}"

    # ── Check bucket ownership ────────────────────────────────
    local bucket_owner_id
    bucket_owner_id=$(aws s3api get-bucket-acl --bucket "$src_bucket" \
        --query 'Owner.ID' --output text 2>/dev/null || echo "UNKNOWN")

    if [[ -n "$MY_CANONICAL_ID" && "$bucket_owner_id" != "UNKNOWN" && "$bucket_owner_id" != "$MY_CANONICAL_ID" ]]; then
        log_warn "Bucket '${src_bucket}' is owned by a different account — skipping."
        log_warn "  Back up this bucket from the account that owns it."
        inc skipped
        return
    fi

    # ── Gather source bucket info ───────────────────────────
    local src_versioning src_encryption src_policy src_tags src_lifecycle src_public_access
    src_versioning=$(aws s3api get-bucket-versioning --bucket "$src_bucket" \
        --query 'Status' --output text 2>/dev/null || echo "None")
    src_encryption=$(aws s3api get-bucket-encryption --bucket "$src_bucket" 2>/dev/null || echo "")
    src_policy=$(aws s3api get-bucket-policy --bucket "$src_bucket" --query 'Policy' --output text 2>/dev/null || echo "")
    src_tags=$(aws s3api get-bucket-tagging --bucket "$src_bucket" 2>/dev/null || echo "")
    src_lifecycle=$(aws s3api get-bucket-lifecycle-configuration --bucket "$src_bucket" 2>/dev/null || echo "")
    src_public_access=$(aws s3api get-public-access-block --bucket "$src_bucket" 2>/dev/null || echo "")

    local obj_count
    obj_count=$(aws s3 ls "s3://${src_bucket}" --recursive --summarize 2>/dev/null | grep "Total Objects:" | awk '{print $3}')
    obj_count="${obj_count:-0}"

    local total_size
    total_size=$(aws s3 ls "s3://${src_bucket}" --recursive --summarize 2>/dev/null | grep "Total Size:" | awk '{print $3}')
    total_size="${total_size:-0}"
    local size_hr
    size_hr=$(numfmt --to=iec "$total_size" 2>/dev/null || echo "${total_size} bytes")

    # ── Confirmation prompt ─────────────────────────────────
    echo ""
    echo -e "${CYAN}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  S3 Cross-Region Backup Plan                     ${CYAN}│${NC}"
    echo -e "${CYAN}├──────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  Account     : ${ACCOUNT_ID}"
    echo -e "${CYAN}│${NC}  Source       : ${src_bucket}"
    echo -e "${CYAN}│${NC}  Source Region: ${SOURCE_REGION}"
    echo -e "${CYAN}│${NC}  Dest Bucket  : ${dest_bucket_base}"
    echo -e "${CYAN}│${NC}  Dest Region  : ${DEST_REGION}"
    echo -e "${CYAN}│${NC}  Versioning   : ${src_versioning}"
    echo -e "${CYAN}│${NC}  Objects      : ${obj_count}"
    echo -e "${CYAN}│${NC}  Total Size   : ${size_hr}"
    echo -e "${CYAN}└──────────────────────────────────────────────────┘${NC}"
    echo ""

    read -rp "Proceed with backup for '${src_bucket}'? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_warn "Skipping ${src_bucket}."
        inc skipped
        return
    fi

    # ── Resolve destination bucket (handles BucketAlreadyExists) ──
    log_step "Resolving destination bucket: ${dest_bucket_base} in ${DEST_REGION}"
    if ! resolve_dest_bucket "$dest_bucket_base"; then
        log_error "Could not create destination bucket for '${src_bucket}' — skipping."
        inc failed
        return
    fi

    local dest_bucket="$RESOLVED_DEST_BUCKET"
    local sync_only=false

    # Track actual dest name (might differ from base if fallback was used)
    if [[ "$dest_bucket" != "$dest_bucket_base" ]]; then
        log_info "Using bucket name: ${dest_bucket}"
    fi

    # If bucket already existed, ask user: sync only or full setup?
    if $DEST_BUCKET_EXISTED; then
        echo ""
        log_info "Destination bucket '${dest_bucket}' already exists."
        read -rp "  (s)ync only, (f)ull setup (config + sync + replication), or s(k)ip? [s/f/k]: " choice
        case "$choice" in
            f|F) sync_only=false ;;
            k|K) log_warn "Skipping ${src_bucket}."; inc skipped; return ;;
            *)   sync_only=true ;;
        esac
    fi

    if $sync_only; then
        # ── Sync only mode ─────────────────────────────────────
        log_step "Syncing objects from ${src_bucket} to ${dest_bucket}..."
        aws s3 sync "s3://${src_bucket}" "s3://${dest_bucket}" \
            --source-region "$SOURCE_REGION" --region "$DEST_REGION"
        log_info "Sync complete."
        inc synced_only
        return
    fi

    # ── Enable versioning on both buckets (required for replication) ──
    log_step "Enabling versioning on both buckets..."
    local src_versioning_failed=false
    if ! aws s3api put-bucket-versioning --bucket "$src_bucket" \
        --versioning-configuration Status=Enabled 2>/dev/null; then
        log_warn "Cannot enable versioning on source bucket '${src_bucket}' (cross-account?)."
        log_warn "  Replication will NOT be configured. Data will be synced via aws s3 sync only."
        src_versioning_failed=true
    fi
    aws s3api put-bucket-versioning --bucket "$dest_bucket" \
        --versioning-configuration Status=Enabled 2>/dev/null || true
    if ! $src_versioning_failed; then
        log_info "Versioning enabled on both buckets."
    fi

    # ── Copy Block Public Access settings (must be done BEFORE bucket policy) ──
    if [[ -n "$src_public_access" ]]; then
        log_step "Applying Block Public Access settings..."
        local block_public_acls ignore_public_acls block_public_policy restrict_public_buckets
        block_public_acls=$(echo "$src_public_access" | jq -r '.PublicAccessBlockConfiguration.BlockPublicAcls')
        ignore_public_acls=$(echo "$src_public_access" | jq -r '.PublicAccessBlockConfiguration.IgnorePublicAcls')
        block_public_policy=$(echo "$src_public_access" | jq -r '.PublicAccessBlockConfiguration.BlockPublicPolicy')
        restrict_public_buckets=$(echo "$src_public_access" | jq -r '.PublicAccessBlockConfiguration.RestrictPublicBuckets')
        aws s3api put-public-access-block --bucket "$dest_bucket" \
            --public-access-block-configuration \
            "BlockPublicAcls=${block_public_acls},IgnorePublicAcls=${ignore_public_acls},BlockPublicPolicy=${block_public_policy},RestrictPublicBuckets=${restrict_public_buckets}" \
            2>/dev/null || log_warn "Could not apply Block Public Access settings."
        log_info "Block Public Access settings applied."
    else
        # Source has no block — remove block on destination so policies can be applied
        log_step "Removing Block Public Access on destination (matching source)..."
        aws s3api delete-public-access-block --bucket "$dest_bucket" 2>/dev/null || true
        log_info "Block Public Access removed on destination."
    fi

    # ── Copy encryption settings ────────────────────────────
    if [[ -n "$src_encryption" ]]; then
        log_step "Applying encryption configuration..."
        local enc_rules
        enc_rules=$(echo "$src_encryption" | jq -c '.ServerSideEncryptionConfiguration')
        aws s3api put-bucket-encryption --bucket "$dest_bucket" \
            --server-side-encryption-configuration "$enc_rules" 2>/dev/null \
            || log_warn "Could not apply encryption settings (may use KMS key not available in ${DEST_REGION})."
    fi

    # ── Copy bucket policy (rewrite bucket name references) ─
    if [[ -n "$src_policy" && "$src_policy" != "None" ]]; then
        log_step "Applying bucket policy..."
        local dest_policy
        # Use jq for safe string replacement (handles newlines, special chars)
        dest_policy=$(echo "$src_policy" | jq --arg src "$src_bucket" --arg dst "$dest_bucket" \
            'gsub($src; $dst)' -r 2>/dev/null || echo "")
        if [[ -n "$dest_policy" ]]; then
            set +e
            local policy_output
            policy_output=$(aws s3api put-bucket-policy --bucket "$dest_bucket" --policy "$dest_policy" 2>&1)
            local policy_rc=$?
            set -e
            if [[ $policy_rc -eq 0 ]]; then
                log_info "Bucket policy applied."
            else
                log_warn "Could not apply bucket policy (may reference resources not available in DR)."
                log_warn "  $policy_output"
            fi
        else
            log_warn "Could not parse bucket policy for rewriting — skipped."
        fi
    else
        log_info "No bucket policy to copy."
    fi

    # ── Copy tags (filter out aws:* system tags) ──────────────
    if [[ -n "$src_tags" ]]; then
        log_step "Applying tags..."
        local tag_set
        tag_set=$(echo "$src_tags" | jq -c '{TagSet: [.TagSet[] | select(.Key | startswith("aws:") | not)]}')
        if [[ $(echo "$tag_set" | jq '.TagSet | length') -gt 0 ]]; then
            aws s3api put-bucket-tagging --bucket "$dest_bucket" --tagging "$tag_set" 2>/dev/null \
                || log_warn "Could not apply tags."
            log_info "Tags applied (system 'aws:' tags excluded)."
        else
            log_info "Only system tags found (aws:*) — skipped."
        fi
    else
        log_info "No tags to copy."
    fi

    # ── Copy lifecycle rules ────────────────────────────────
    if [[ -n "$src_lifecycle" ]]; then
        log_step "Applying lifecycle configuration..."
        aws s3api put-bucket-lifecycle-configuration --bucket "$dest_bucket" \
            --lifecycle-configuration "$src_lifecycle" 2>/dev/null \
            || log_warn "Could not apply lifecycle configuration."
        log_info "Lifecycle configuration applied."
    else
        log_info "No lifecycle configuration to copy."
    fi

    # ── Sync objects ────────────────────────────────────────
    log_step "Syncing objects from ${src_bucket} to ${dest_bucket}..."
    aws s3 sync "s3://${src_bucket}" "s3://${dest_bucket}" \
        --source-region "$SOURCE_REGION" --region "$DEST_REGION"
    log_info "Sync complete."

    # ── Set up replication rule ─────────────────────────────
    if $src_versioning_failed; then
        log_warn "Skipping replication setup (source versioning could not be enabled)."
        log_warn "  Data was synced. Re-run from the owning account to enable replication."
        inc synced_only
        return
    fi

    log_step "Configuring replication rule on ${src_bucket}..."
    local replication_config
    replication_config=$(cat <<REPL
{
    "Role": "${REPLICATION_ROLE_ARN}",
    "Rules": [
        {
            "ID": "backup-replication-to-${DEST_REGION}",
            "Status": "Enabled",
            "Priority": 0,
            "Filter": {},
            "Destination": {
                "Bucket": "arn:aws:s3:::${dest_bucket}",
                "StorageClass": "STANDARD"
            },
            "DeleteMarkerReplication": {
                "Status": "Enabled"
            }
        }
    ]
}
REPL
)

    set +e
    repl_output=$(aws s3api put-bucket-replication --bucket "$src_bucket" \
        --replication-configuration "$replication_config" 2>&1)
    repl_rc=$?
    set -e

    if [[ $repl_rc -eq 0 ]]; then
        log_info "Replication rule configured: ${src_bucket} -> ${dest_bucket}"
        inc replicated
    else
        log_warn "Could not configure replication on '${src_bucket}':"
        log_warn "  $repl_output"
        log_warn "  Data was synced via aws s3 sync. Replication must be set up manually."
        inc synced_only
    fi
}

# ── Main execution ──────────────────────────────────────────
replicated=0
synced_only=0
skipped=0
failed=0

echo ""
log_step "Setting up IAM replication role..."
create_replication_role

for bucket in "${SELECTED_BUCKETS[@]}"; do
    process_bucket "$bucket"
done

# ── Summary ─────────────────────────────────────────────────
echo ""
log_step "Summary"
echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
log_info "Replicated (sync + replication) : ${replicated}"
log_info "Synced only (no replication)    : ${synced_only}"
log_info "Skipped                         : ${skipped}"
log_info "Failed                          : ${failed}"
echo -e "${CYAN}──────────────────────────────────────────────────${NC}"

if [[ $replicated -gt 0 || $synced_only -gt 0 ]]; then
    echo ""
    log_info "New objects will be automatically replicated for buckets with replication enabled."
    log_info "Existing objects were synced using 'aws s3 sync'."
    echo ""
    log_info "Verify replication status:"
    echo "  aws s3api get-bucket-replication --bucket <source-bucket> --region ${SOURCE_REGION}"
fi
