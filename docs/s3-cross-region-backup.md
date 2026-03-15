# s3-cross-region-backup.sh

Discovers S3 buckets in the source region, creates corresponding backup buckets in the DR region, syncs existing objects, and sets up ongoing S3 Cross-Region Replication (CRR) rules for disaster recovery.

## Overview

| Attribute | Value |
|-----------|-------|
| **File** | `s3-cross-region-backup.sh` |
| **Default source region** | `me-south-1` (Bahrain), or `$SOURCE_REGION` |
| **Default DR region** | `eu-west-1` (Ireland), or `$DEST_REGION` |
| **Default backup suffix** | `-backup`, or `$BACKUP_SUFFIX` |
| **Requires** | AWS CLI v2, `jq` |

## Usage

```bash
./s3-cross-region-backup.sh
```

Override settings via environment variables:

```bash
SOURCE_REGION=ap-southeast-1 DEST_REGION=eu-west-1 BACKUP_SUFFIX=-dr ./s3-cross-region-backup.sh
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SOURCE_REGION` | `me-south-1` | Primary AWS region |
| `DEST_REGION` | `eu-west-1` | DR AWS region |
| `BACKUP_SUFFIX` | `-backup` | Suffix appended to backup bucket names |

## What It Does

For each S3 bucket in the source region:

1. **Ownership check** — Skips buckets not owned by the current account (cross-account buckets).
2. **Creates a backup bucket** in the DR region named `<original-name><BACKUP_SUFFIX>`:
   - Falls back to `<original-name>-<account-id><BACKUP_SUFFIX>` if the name is already taken.
3. **Copies bucket configuration** to the backup bucket:
   - Versioning
   - Server-side encryption (SSE-S3 or SSE-KMS)
   - Block Public Access settings
   - Bucket policy
   - Tags (AWS system tags like `aws:*` are filtered out)
   - Lifecycle rules
4. **Syncs existing objects** — Runs `aws s3 sync` to copy all existing objects from source to backup bucket.
5. **Sets up replication** — Configures S3 Cross-Region Replication (CRR) on the source bucket to replicate all new objects to the backup bucket automatically.

## Bucket Naming

| Source Bucket | Backup Bucket |
|---------------|--------------|
| `my-app-data` | `my-app-data-backup` |
| `prod-logs` | `prod-logs-backup` |

If the backup bucket name is already taken by another account, a fallback name is used:
`my-app-data-123456789012-backup`

## Replication Requirements

S3 Cross-Region Replication requires:

- **Versioning enabled** on both source and destination buckets (the script enables this automatically).
- An IAM role with permissions to replicate objects. The script creates a role named `s3-replication-role` if it does not exist.

## IAM Permissions Required

```json
{
  "Effect": "Allow",
  "Action": [
    "s3:ListAllMyBuckets",
    "s3:GetBucketLocation",
    "s3:CreateBucket",
    "s3:GetBucketVersioning",
    "s3:PutBucketVersioning",
    "s3:GetBucketEncryption",
    "s3:PutBucketEncryption",
    "s3:GetBucketPublicAccessBlock",
    "s3:PutPublicAccessBlock",
    "s3:GetBucketPolicy",
    "s3:PutBucketPolicy",
    "s3:GetBucketTagging",
    "s3:PutBucketTagging",
    "s3:GetLifecycleConfiguration",
    "s3:PutLifecycleConfiguration",
    "s3:GetBucketReplication",
    "s3:PutReplicationConfiguration",
    "s3:GetObject",
    "s3:PutObject",
    "s3:ReplicateObject",
    "iam:CreateRole",
    "iam:AttachRolePolicy",
    "iam:GetRole",
    "iam:PassRole",
    "sts:GetCallerIdentity"
  ],
  "Resource": "*"
}
```

## Notes

- The script prompts for confirmation before processing each bucket.
- The initial `aws s3 sync` may take a significant amount of time for large buckets.
- After replication is configured, only **new** objects written to the source bucket are replicated automatically. Objects written before replication was set up are covered by the initial sync.
- Buckets in the source region with no objects or that fail the ownership check are skipped gracefully.
- Cross-account replication scenarios (buckets owned by another account) are detected and skipped with a warning.
