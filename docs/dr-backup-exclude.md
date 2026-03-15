# dr-backup-exclude.sh

Updates existing AWS Backup selections to exclude EC2 instances tagged with `backup-exclude=true`, preventing those instances from being included in future backup jobs.

## Overview

| Attribute | Value |
|-----------|-------|
| **File** | `dr-backup-exclude.sh` |
| **Default region** | `me-south-1` (Bahrain), or `$AWS_DEFAULT_REGION` |
| **Requires** | AWS CLI v2, `jq` |

## Usage

```bash
./dr-backup-exclude.sh [--region REGION]
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--region REGION` | `$AWS_DEFAULT_REGION` or `me-south-1` | AWS region to operate in |

## Examples

```bash
# Use default region
./dr-backup-exclude.sh

# Specify region
./dr-backup-exclude.sh --region eu-west-1
```

## What It Does

1. **Finds tagged instances** — Lists all EC2 instances with the tag `backup-exclude=true`.
2. **Lists backup plans** — Fetches all AWS Backup plans and their backup selections.
3. **Filters applicable selections** — Only processes selections that use wildcard (`*`) resource matching or tag-based conditions. Skips selections with specific ARN lists (the exclusion tag approach does not apply there).
4. **Checks for existing exclusions** — Skips selections that already have the `backup-exclude=true` exclusion condition.
5. **Updates selections** — For each applicable selection, adds a `StringNotEquals` condition on `aws:ResourceTag/backup-exclude = true` to the selection's `Conditions`, effectively excluding tagged instances.
6. **Recovery on failure** — If updating a selection fails after the old selection was deleted, the script automatically attempts to restore the original selection.

## Tagging Instances for Exclusion

Tag an instance manually:

```bash
aws ec2 create-tags \
  --resources i-0123456789abcdef0 \
  --tags Key=backup-exclude,Value=true \
  --region me-south-1
```

Or run `dr-cleanup.sh` first — it tags stopped instances with `backup-exclude=true` automatically.

## How the Exclusion Works

The script adds a condition to the AWS Backup selection's `Conditions.StringNotEquals` array:

```json
{
  "ConditionKey": "aws:ResourceTag/backup-exclude",
  "ConditionValue": "true"
}
```

This tells AWS Backup to skip any resource that has the tag `backup-exclude=true`, even if the selection uses a wildcard or tag-based match.

## Reversing the Exclusion

To remove the exclusion tag from an instance and resume backups:

```bash
aws ec2 delete-tags \
  --resources i-0123456789abcdef0 \
  --tags Key=backup-exclude \
  --region me-south-1
```

> **Note:** Removing the tag resumes future backups. Existing recovery points in the vault are **not** deleted.

## IAM Permissions Required

```json
{
  "Effect": "Allow",
  "Action": [
    "backup:ListBackupPlans",
    "backup:ListBackupSelections",
    "backup:GetBackupSelection",
    "backup:CreateBackupSelection",
    "backup:DeleteBackupSelection",
    "ec2:DescribeInstances",
    "sts:GetCallerIdentity",
    "iam:ListAccountAliases"
  ],
  "Resource": "*"
}
```

## Notes

- Only wildcard and tag-based backup selections can be updated with this exclusion approach. Selections with explicit resource ARN lists must be managed differently (e.g., remove the stopped instance ARN using `dr-cleanup.sh`).
- The script prompts for confirmation before updating each selection.
- Existing backup recovery points are **not** affected.
