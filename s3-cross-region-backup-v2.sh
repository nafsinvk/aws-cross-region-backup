#!/bin/bash
set -euo pipefail

# ============================================================
# S3 Cross-Region Backup & Replication Setup Script (v2)
# ============================================================
# Dynamically discovers AWS account, lists buckets in source
# region, creates backup bucket in destination region, copies
# configuration & data, and sets up replication rules.
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

# ── Pre-flight checks ──────────────────────────────────────
command -v aws >/dev/null 2>&1 || { log_error "AWS CLI not found. Install it first."; exit 1; }
command -v jq >/dev/null 2>&1 || { log_error "jq not found. Install it first."; exit 1; }

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

# ── Process each selected bucket ────────────────────────────
process_bucket() {
    local src_bucket="$1"
    local dest_bucket="${src_bucket}${BACKUP_SUFFIX}"

    log_step "Processing: ${src_bucket} -> ${dest_bucket}"

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
    echo -e "${CYAN}│${NC}  Backup Plan                                     ${CYAN}│${NC}"
    echo -e "${CYAN}├──────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  Account     : ${ACCOUNT_ID}                    ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  Source       : ${src_bucket}                    "
    echo -e "${CYAN}│${NC}  Source Region: ${SOURCE_REGION}                 "
    echo -e "${CYAN}│${NC}  Dest Bucket  : ${dest_bucket}                   "
    echo -e "${CYAN}│${NC}  Dest Region  : ${DEST_REGION}                   "
    echo -e "${CYAN}│${NC}  Versioning   : ${src_versioning}                "
    echo -e "${CYAN}│${NC}  Objects      : ${obj_count}                     "
    echo -e "${CYAN}│${NC}  Total Size   : ${size_hr}                       "
    echo -e "${CYAN}└──────────────────────────────────────────────────┘${NC}"
    echo ""

    read -rp "Proceed with creating backup bucket '${dest_bucket}'? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_warn "Skipping ${src_bucket}."
        return
    fi

    # ── Create destination bucket ───────────────────────────
    log_step "Creating bucket: ${dest_bucket} in ${DEST_REGION}"
    if aws s3api head-bucket --bucket "$dest_bucket" 2>/dev/null; then
        log_info "Bucket ${dest_bucket} already exists."
    else
        aws s3api create-bucket --bucket "$dest_bucket" \
            --region "$DEST_REGION" \
            --create-bucket-configuration LocationConstraint="$DEST_REGION"
        log_info "Created bucket: ${dest_bucket}"
    fi

    # ── Enable versioning on both buckets (required for replication) ──
    log_step "Enabling versioning on both buckets..."
    aws s3api put-bucket-versioning --bucket "$src_bucket" \
        --versioning-configuration Status=Enabled
    aws s3api put-bucket-versioning --bucket "$dest_bucket" \
        --versioning-configuration Status=Enabled
    log_info "Versioning enabled on both buckets."

    # ── Copy Block Public Access settings (must be done BEFORE bucket policy) ──
    if [[ -n "$src_public_access" ]]; then
        log_step "Applying Block Public Access settings..."
        local block_public_acls restrict_public_buckets block_public_policy ignore_public_acls
        block_public_acls=$(echo "$src_public_access" | jq -r '.PublicAccessBlockConfiguration.BlockPublicAcls')
        ignore_public_acls=$(echo "$src_public_access" | jq -r '.PublicAccessBlockConfiguration.IgnorePublicAcls')
        block_public_policy=$(echo "$src_public_access" | jq -r '.PublicAccessBlockConfiguration.BlockPublicPolicy')
        restrict_public_buckets=$(echo "$src_public_access" | jq -r '.PublicAccessBlockConfiguration.RestrictPublicBuckets')
        aws s3api put-public-access-block --bucket "$dest_bucket" \
            --public-access-block-configuration \
            "BlockPublicAcls=${block_public_acls},IgnorePublicAcls=${ignore_public_acls},BlockPublicPolicy=${block_public_policy},RestrictPublicBuckets=${restrict_public_buckets}"
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
            --server-side-encryption-configuration "$enc_rules"
        log_info "Encryption configuration applied."
    fi

    # ── Copy bucket policy (rewrite bucket name references) ─
    if [[ -n "$src_policy" && "$src_policy" != "None" ]]; then
        log_step "Applying bucket policy..."
        local dest_policy
        dest_policy=$(echo "$src_policy" | sed "s/${src_bucket}/${dest_bucket}/g")
        aws s3api put-bucket-policy --bucket "$dest_bucket" --policy "$dest_policy"
        log_info "Bucket policy applied."
    else
        log_info "No bucket policy to copy."
    fi

    # ── Copy tags ───────────────────────────────────────────
    if [[ -n "$src_tags" ]]; then
        log_step "Applying tags..."
        local tag_set
        tag_set=$(echo "$src_tags" | jq -c '{TagSet: .TagSet}')
        aws s3api put-bucket-tagging --bucket "$dest_bucket" --tagging "$tag_set"
        log_info "Tags applied."
    else
        log_info "No tags to copy."
    fi

    # ── Copy lifecycle rules ────────────────────────────────
    if [[ -n "$src_lifecycle" ]]; then
        log_step "Applying lifecycle configuration..."
        aws s3api put-bucket-lifecycle-configuration --bucket "$dest_bucket" \
            --lifecycle-configuration "$src_lifecycle"
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

    aws s3api put-bucket-replication --bucket "$src_bucket" \
        --replication-configuration "$replication_config"
    log_info "Replication rule configured: ${src_bucket} -> ${dest_bucket}"
}

# ── Main execution ──────────────────────────────────────────
echo ""
log_step "Setting up IAM replication role..."
create_replication_role

for bucket in "${SELECTED_BUCKETS[@]}"; do
    process_bucket "$bucket"
done

echo ""
log_step "All done!"
log_info "Summary of replication setup:"
for bucket in "${SELECTED_BUCKETS[@]}"; do
    echo -e "  ${GREEN}✓${NC} ${bucket} (${SOURCE_REGION}) -> ${bucket}${BACKUP_SUFFIX} (${DEST_REGION})"
done
echo ""
log_info "New objects will be automatically replicated via S3 replication rules."
log_info "Existing objects were synced using 'aws s3 sync'."
