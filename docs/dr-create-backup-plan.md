# dr-create-backup-plan.sh

Creates an AWS Backup plan for specified EC2 instances with daily snapshots in the source region and automatic cross-region copies to a DR vault.

## Overview

| Attribute | Value |
|-----------|-------|
| **File** | `dr-create-backup-plan.sh` |
| **Default source region** | `me-south-1` (Bahrain) |
| **Default DR region** | `eu-west-1` (Ireland) |
| **Requires** | AWS CLI v2, `jq` |

## Usage

```bash
./dr-create-backup-plan.sh --plan-name NAME --instance-ids "i-xxx ..." [options]
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--plan-name NAME` | _(required)_ | Name for the backup plan |
| `--instance-ids "i-x i-y"` | _(required)_ | Space-separated EC2 instance IDs |
| `--region SOURCE_REGION` | `me-south-1` | Source AWS region |
| `--dr-region DR_REGION` | `eu-west-1` | DR AWS region |
| `--local-retention DAYS` | `3` | Days to keep local snapshots |
| `--dr-retention DAYS` | `30` | Days to keep DR copies |
| `--schedule CRON` | `cron(0 1 * * ? *)` | Backup schedule (daily at 1:00 AM UTC) |

## Examples

### Basic Usage

```bash
./dr-create-backup-plan.sh \
  --plan-name "DailyBackupToIreland" \
  --instance-ids "i-0123456789abcdef0"
```

### Custom Regions and Retention

```bash
./dr-create-backup-plan.sh \
  --plan-name "ProdDRPlan" \
  --instance-ids "i-0123456789abcdef0 i-0fedcba9876543210" \
  --region ap-southeast-1 \
  --dr-region eu-west-1 \
  --local-retention 7 \
  --dr-retention 90
```

### Custom Schedule

```bash
./dr-create-backup-plan.sh \
  --plan-name "HourlyBackup" \
  --instance-ids "i-0123456789abcdef0" \
  --schedule "cron(0 */6 * * ? *)"
```

## What It Does

1. **Validates instances** — Checks each provided instance ID exists in the source region. Warns if an instance is stopped.
2. **Ensures backup vaults exist** — Creates the `Default` vault in the source region and `DR-Backup-Vault` in the DR region if they do not exist.
3. **Creates an IAM role** — Creates `AWSBackupServiceRole-<plan-name>` with the AWS managed backup and restore policies attached. Waits 10 seconds for IAM propagation.
4. **Creates the backup plan** — Daily backup rule with cross-region copy action:
   - Source: `Default` vault in `SOURCE_REGION`
   - Destination: `DR-Backup-Vault` in `DR_REGION`
   - Local retention: `LOCAL_RETENTION` days
   - DR retention: `DR_RETENTION` days
5. **Creates a backup selection** — Assigns the specified EC2 instances by ARN to the plan.

## Backup Flow

```
Daily at 1:00 AM UTC
       │
       ▼
 Snapshot in SOURCE_REGION
 (vault: Default)
       │
       ▼
 Copy to DR_REGION
 (vault: DR-Backup-Vault)
       │
       ├── Local copy deleted after LOCAL_RETENTION days
       └── DR copy deleted after DR_RETENTION days
```

## Estimated Cost

| Item | Estimated Monthly Cost |
|------|----------------------|
| Local snapshots (3-day retention) | ~$1–3 |
| DR copies in `eu-west-1` (30-day retention) | ~$5–15 |
| **Total** | **~$6–18** (varies by EBS volume size) |

## IAM Permissions Required

```json
{
  "Effect": "Allow",
  "Action": [
    "backup:ListBackupPlans",
    "backup:CreateBackupPlan",
    "backup:DeleteBackupPlan",
    "backup:CreateBackupSelection",
    "backup:DescribeBackupVault",
    "backup:CreateBackupVault",
    "ec2:DescribeInstances",
    "iam:CreateRole",
    "iam:AttachRolePolicy",
    "iam:GetRole",
    "iam:PassRole",
    "sts:GetCallerIdentity",
    "iam:ListAccountAliases"
  ],
  "Resource": "*"
}
```

## Notes

- If a backup plan with the same name already exists, the script will prompt to delete and recreate it.
- Stopped instances will generate a warning and prompt for confirmation before being included.
- This script is also available as the `create` sub-command of `dr-backup-manager.sh`.
