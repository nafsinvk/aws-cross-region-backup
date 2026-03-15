# dr-cleanup.sh

Identifies and cleans up wasteful AWS resources: removes backup selections that are backing up stopped EC2 instances, and releases unattached Elastic IP addresses (EIPs) to reduce unnecessary AWS costs.

## Overview

| Attribute | Value |
|-----------|-------|
| **File** | `dr-cleanup.sh` |
| **Default region** | `me-south-1` (Bahrain), or `$AWS_DEFAULT_REGION` |
| **Requires** | AWS CLI v2, `jq` |

## Usage

```bash
./dr-cleanup.sh [--region REGION]
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--region REGION` | `$AWS_DEFAULT_REGION` or `me-south-1` | AWS region to operate in |

## Examples

```bash
# Use default region
./dr-cleanup.sh

# Specify region
./dr-cleanup.sh --region eu-west-1
```

## What It Does

### Section 1: Backup Plans on Stopped Instances

1. Lists all stopped EC2 instances in the region.
2. Scans all AWS Backup plans and their selections.
3. For each backup selection, identifies which stopped instances are targeted.
4. For each affected selection:
   - Shows details (plan name, selection name, instance list)
   - Offers options:
     - **Remove stopped instances** from the selection and tag them `backup-exclude=true`
     - **Delete the entire selection** if only stopped instances are targeted
     - **Skip** and leave unchanged
5. Prints a summary of changes made.

### Section 2: Unattached Elastic IPs

1. Lists all Elastic IPs in the region that are not associated with any instance or network interface.
2. For each unattached EIP, displays the allocation ID, public IP, and any name tags.
3. Prompts whether to release it (charges stop immediately upon release).
4. Prints a summary of released and skipped EIPs.

## Confirmation Prompts

The script prompts `(y/n)` before every destructive action. No changes are made without explicit confirmation.

## After Cleanup

Run `dr-backup-exclude.sh` to add the `backup-exclude=true` exclusion condition to wildcard/tag-based backup selections, ensuring newly tagged instances are skipped automatically:

```bash
./dr-backup-exclude.sh --region me-south-1
```

## IAM Permissions Required

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:DescribeInstances",
    "ec2:DescribeAddresses",
    "ec2:CreateTags",
    "ec2:ReleaseAddress",
    "backup:ListBackupPlans",
    "backup:ListBackupSelections",
    "backup:GetBackupSelection",
    "backup:CreateBackupSelection",
    "backup:DeleteBackupSelection",
    "sts:GetCallerIdentity",
    "iam:ListAccountAliases"
  ],
  "Resource": "*"
}
```

## Notes

- Existing AWS Backup recovery points (snapshots) are **not** deleted — only the backup selection rules are modified.
- Releasing an EIP is immediate and irreversible. Ensure you no longer need the IP before confirming.
- The script is also available as the `cleanup` sub-command of `dr-backup-manager.sh`, which supports `--dry-run` mode.
