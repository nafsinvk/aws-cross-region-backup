# s3-cross-region-backup-v2.sh

An enhanced interactive script for setting up S3 cross-region replication and syncing existing objects from a source region to a DR region. Version 2 adds interactive bucket discovery and selection, full configuration mirroring, and a streamlined IAM role setup.

## Overview

| Attribute | Value |
|-----------|-------|
| **File** | `s3-cross-region-backup-v2.sh` |
| **Default source region** | `me-south-1` (Bahrain), or `$SOURCE_REGION` |
| **Default DR region** | `eu-west-1` (Ireland), or `$DEST_REGION` |
| **Requires** | AWS CLI v2, `jq` |

## Usage

```bash
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./s3-cross-region-backup-v2.sh
```

The script prompts interactively at each stage — region confirmation, bucket selection, and per-bucket confirmation — so no additional flags are required.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SOURCE_REGION` | `me-south-1` | Primary AWS region |
| `DEST_REGION` | `eu-west-1` | DR AWS region |
| `BACKUP_SUFFIX` | `-backup` | Suffix appended to destination bucket names |

## Examples

```bash
# Use default regions (me-south-1 -> eu-west-1)
./s3-cross-region-backup-v2.sh

# Override regions via environment variables
SOURCE_REGION=us-east-1 DEST_REGION=us-west-2 ./s3-cross-region-backup-v2.sh

# Use a custom backup bucket suffix
BACKUP_SUFFIX=-dr ./s3-cross-region-backup-v2.sh
```

## Interactive Flow

1. **Identity detection** — Displays the AWS account ID and caller ARN.
2. **Region prompts** — Confirms (or overrides) the source and destination regions.
3. **Bucket discovery** — Lists all S3 buckets located in the source region.
4. **Bucket selection** — Enter bucket numbers (comma-separated) or `all` to select every bucket.
5. **IAM role setup** — Creates or updates the `s3-replication-role-<account-id>` IAM role and its attached policy.
6. **Per-bucket processing** — For each selected bucket:
   - Displays a summary panel (account, source/dest bucket names, regions, versioning status, object count, total size).
   - Prompts for confirmation before making any changes.
   - Creates the destination bucket in the DR region.
   - Enables versioning on both source and destination (required for replication).
   - Mirrors Block Public Access settings.
   - Copies encryption configuration.
   - Copies bucket policy (rewrites bucket name references).
   - Copies tags.
   - Copies lifecycle rules.
   - Syncs all existing objects with `aws s3 sync`.
   - Configures a Cross-Region Replication (CRR) rule for ongoing replication.
7. **Summary** — Prints a list of all configured replication pairs.

## What v2 Adds Over v1

| Feature | v1 | v2 |
|---------|----|----|
| Interactive region prompt | No | Yes |
| Interactive bucket selection | No | Yes (numbered list or `all`) |
| Per-bucket confirmation panel | No | Yes (shows size, object count) |
| Block Public Access mirroring | No | Yes |
| Encryption config mirroring | No | Yes |
| Bucket policy mirroring | No | Yes (rewrites bucket name references) |
| Tag mirroring | No | Yes |
| Lifecycle rule mirroring | No | Yes |
| IAM policy update (idempotent) | No | Yes |

## IAM Permissions Required

```json
{
  "Effect": "Allow",
  "Action": [
    "sts:GetCallerIdentity",
    "s3:ListAllMyBuckets",
    "s3:GetBucketLocation",
    "s3:GetBucketVersioning",
    "s3:PutBucketVersioning",
    "s3:GetBucketEncryption",
    "s3:PutBucketEncryption",
    "s3:GetBucketPolicy",
    "s3:PutBucketPolicy",
    "s3:GetBucketTagging",
    "s3:PutBucketTagging",
    "s3:GetLifecycleConfiguration",
    "s3:PutLifecycleConfiguration",
    "s3:GetPublicAccessBlock",
    "s3:PutPublicAccessBlock",
    "s3:DeletePublicAccessBlock",
    "s3:CreateBucket",
    "s3:HeadBucket",
    "s3:ListBucket",
    "s3:GetObject",
    "s3:PutObject",
    "s3:GetBucketReplication",
    "s3:PutBucketReplication",
    "iam:GetRole",
    "iam:CreateRole",
    "iam:GetPolicy",
    "iam:CreatePolicy",
    "iam:CreatePolicyVersion",
    "iam:ListPolicyVersions",
    "iam:DeletePolicyVersion",
    "iam:AttachRolePolicy"
  ],
  "Resource": "*"
}
```

## Notes

- **Versioning is enabled** on both the source and destination bucket if not already active — this is required for S3 Cross-Region Replication.
- The **destination bucket name** is `<source-bucket-name><BACKUP_SUFFIX>` (default: `<source-bucket-name>-backup`). Ensure the name is globally unique.
- The IAM replication role (`s3-replication-role-<account-id>`) and policy are created once and reused across all buckets. The policy grants wildcard permissions on buckets matching the `*<BACKUP_SUFFIX>` pattern to stay within the IAM 6,144-byte policy size limit.
- **Existing objects** are synced using `aws s3 sync`. Only new and changed objects are copied, so re-running the script is safe.
- **Ongoing replication** (new objects) is handled by the S3 CRR rule applied to the source bucket.
- Bucket policies are copied with source bucket name references rewritten to the destination bucket name; review the policy in the destination account after migration.
