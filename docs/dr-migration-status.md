# dr-migration-status.sh

Checks the overall Disaster Recovery (DR) readiness of your AWS account by scanning multiple services across both source and DR regions.

## Overview

| Attribute | Value |
|-----------|-------|
| **File** | `dr-migration-status.sh` |
| **Default source region** | `me-south-1` (Bahrain), or `$SOURCE_REGION` |
| **Default DR region** | `eu-west-1` (Ireland), or `$DEST_REGION` |
| **Requires** | AWS CLI v2, `jq` |

## Usage

```bash
./dr-migration-status.sh [--region SOURCE_REGION] [--dr-region DR_REGION]
```

Or via environment variables:

```bash
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./dr-migration-status.sh
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--region SOURCE_REGION` | `me-south-1` | Primary AWS region |
| `--dr-region DR_REGION` | `eu-west-1` | Disaster Recovery region |

## What It Checks

| Check | Description |
|-------|-------------|
| **1. AWS Backup Plans** | Whether backup plans exist, have DR copy rules, and have recovery points in the DR vault |
| **2. DR Backup Vault** | Whether the `DR-Backup-Vault` exists in the DR region and contains recovery points |
| **3. S3 Cross-Region Replication** | Per-bucket CRR status — which buckets replicate to the DR region |
| **4. RDS Cross-Region Read Replicas** | Which RDS instances have read replicas in the DR region |
| **5. ECR Cross-Region Replication** | Whether ECR is configured to replicate images to the DR region |
| **6. EC2 Backup Coverage** | Which running EC2 instances are covered by a backup plan |
| **7. Route 53 / DNS Failover** | Whether Route 53 health checks and failover routing are configured |
| **8. ACM Certificates in DR Region** | Whether SSL/TLS certificates are provisioned in the DR region |

## Output Format

Each check prints a status indicator:

| Symbol | Meaning |
|--------|---------|
| ✓ (green) | Healthy / configured correctly |
| ⚠ (yellow) | Warning / partially configured |
| ✗ (red) | Missing / not configured |
| – (cyan) | Skipped / not applicable |

At the end, a summary shows pass/warn/fail counts and an overall DR readiness score.

## Example Output

```
==> AWS Backup Plans
    ✓ ProdDRPlan — has DR copy rule to eu-west-1
    ✓ DR-Backup-Vault exists in eu-west-1 (42 recovery points)

==> S3 Cross-Region Replication
    ✓ my-app-data — replicates to eu-west-1
    ⚠ my-logs-bucket — no replication configured

==> RDS Cross-Region Replicas
    ✓ prod-db — replica exists in eu-west-1

==> EC2 Backup Coverage
    ✓ i-0123456789abcdef0 (web-server) — covered by ProdDRPlan
    ✗ i-0fedcba9876543210 (batch-worker) — NOT covered by any backup plan
```

## IAM Permissions Required

The script performs **read-only** operations:

```json
{
  "Effect": "Allow",
  "Action": [
    "backup:ListBackupPlans",
    "backup:GetBackupPlan",
    "backup:ListBackupSelections",
    "backup:GetBackupSelection",
    "backup:DescribeBackupVault",
    "backup:ListRecoveryPointsByBackupVault",
    "s3:ListAllMyBuckets",
    "s3:GetBucketReplication",
    "s3:GetBucketLocation",
    "rds:DescribeDBInstances",
    "ecr:DescribeReplicationConfiguration",
    "ec2:DescribeInstances",
    "route53:ListHostedZones",
    "route53:ListHealthChecks",
    "route53:ListResourceRecordSets",
    "acm:ListCertificates",
    "sts:GetCallerIdentity",
    "iam:ListAccountAliases"
  ],
  "Resource": "*"
}
```

## Notes

- The script is entirely **read-only** — it makes no changes to any resources.
- Run this script before and after setting up DR components to verify progress.
- Use in combination with `dr-inventory.sh` for a full pre-DR baseline report.
