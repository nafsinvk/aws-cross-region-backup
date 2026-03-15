# dr-backup-manager.sh

An all-in-one AWS Backup management script that combines auditing, cleanup, and backup plan creation into a single tool with three sub-commands.

## Overview

| Attribute | Value |
|-----------|-------|
| **File** | `dr-backup-manager.sh` |
| **Default source region** | `me-south-1` (Bahrain) |
| **Default DR region** | `eu-west-1` (Ireland) |
| **Requires** | AWS CLI v2, `jq` |

## Usage

```bash
./dr-backup-manager.sh <command> [options]
```

### Commands

| Command | Description |
|---------|-------------|
| `audit` | Read-only scan of backup plans, stopped instances, and Elastic IPs |
| `cleanup` | Interactively remove wasteful backups and release unattached EIPs |
| `create` | Create a new daily backup plan with cross-region DR copy |

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--region REGION` | `me-south-1` | Source AWS region |
| `--dr-region REGION` | `eu-west-1` | Disaster Recovery region |
| `--plan-name NAME` | _(required for create)_ | Backup plan name |
| `--instance-ids "i-x i-y"` | _(required for create)_ | Space-separated EC2 instance IDs |
| `--local-retention DAYS` | `3` | Local backup retention in days |
| `--dr-retention DAYS` | `30` | DR copy retention in days |
| `--dry-run` | `false` | Preview actions without making changes |

## Examples

### Audit

Scan backup plans, identify stopped instances being backed up, and list unattached EIPs (read-only, no changes made):

```bash
./dr-backup-manager.sh audit --region me-south-1 --dr-region eu-west-1
```

### Cleanup

Remove backup selections targeting stopped instances and release unattached EIPs (prompts for confirmation before each change):

```bash
./dr-backup-manager.sh cleanup --region me-south-1
```

Preview cleanup without making changes:

```bash
./dr-backup-manager.sh cleanup --region me-south-1 --dry-run
```

### Create Backup Plan

Create a daily backup plan with automatic cross-region copy:

```bash
./dr-backup-manager.sh create \
  --plan-name "ProdDR" \
  --instance-ids "i-0123456789abcdef0 i-0fedcba9876543210" \
  --region me-south-1 \
  --dr-region eu-west-1 \
  --local-retention 3 \
  --dr-retention 30
```

## What It Does

### `audit` sub-command

1. Lists all AWS Backup plans and their selections
2. Identifies backup selections that target stopped EC2 instances (wasteful backups)
3. Lists all unattached Elastic IP addresses (ongoing cost)
4. Reports on DR copy rules in existing backup plans
5. **No changes are made**

### `cleanup` sub-command

1. Finds backup selections that are backing up stopped instances
2. Offers to remove those selections (with confirmation)
3. Tags stopped instances with `backup-exclude=true`
4. Finds unattached EIPs and offers to release them (with confirmation)
5. Prints a cost-savings summary

### `create` sub-command

1. Validates the provided EC2 instance IDs exist
2. Ensures backup vaults exist in both source and DR regions (creates if needed)
3. Creates or reuses an IAM role (`AWSBackupServiceRole-<plan-name>`) for AWS Backup
4. Creates a backup plan with:
   - Daily snapshot at 1:00 AM UTC
   - Local retention: configurable (default 3 days)
   - Automatic copy to DR vault
   - DR retention: configurable (default 30 days)
5. Creates a backup selection assigning the specified instances to the plan

## IAM Permissions Required

```json
{
  "Effect": "Allow",
  "Action": [
    "backup:ListBackupPlans",
    "backup:ListBackupSelections",
    "backup:GetBackupSelection",
    "backup:CreateBackupPlan",
    "backup:DeleteBackupPlan",
    "backup:CreateBackupSelection",
    "backup:DeleteBackupSelection",
    "backup:DescribeBackupVault",
    "backup:CreateBackupVault",
    "ec2:DescribeInstances",
    "ec2:DescribeAddresses",
    "ec2:CreateTags",
    "ec2:ReleaseAddress",
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

- The `cleanup` and `create` sub-commands prompt for confirmation before making any destructive or additive changes.
- Use `--dry-run` with `cleanup` to safely preview what would be changed.
- The script automatically handles IAM role creation and propagation delays.
- Existing backup plans with the same name will prompt before being deleted and recreated.
