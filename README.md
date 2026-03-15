# AWS Cross-Region Backup

A collection of Bash scripts for setting up, managing, and auditing **AWS Disaster Recovery (DR)** and **cross-region backup** infrastructure. These scripts automate common DR tasks across EC2, RDS, S3, ECR, and AWS Backup services.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Scripts](#scripts)
  - [dr-backup-manager.sh](#dr-backup-managersh)
  - [dr-create-backup-plan.sh](#dr-create-backup-plansh)
  - [dr-backup-exclude.sh](#dr-backup-excludesh)
  - [dr-cleanup.sh](#dr-cleanupsh)
  - [dr-inventory.sh](#dr-inventorysh)
  - [dr-migration-status.sh](#dr-migration-statussh)
  - [dr-serverless-migrate.sh](#dr-serverless-migratesh)
  - [rds-cross-region-replica.sh](#rds-cross-region-replicash)
  - [s3-cross-region-backup.sh](#s3-cross-region-backupsh)
- [IAM Permissions](#iam-permissions)
- [Recommended Workflow](#recommended-workflow)
- [Default Region Configuration](#default-region-configuration)

---

## Overview

These scripts help you build and manage a cross-region DR strategy on AWS:

| Script | Purpose |
|--------|---------|
| `dr-backup-manager.sh` | All-in-one: audit backups, clean up waste, and create DR backup plans |
| `dr-create-backup-plan.sh` | Create a daily AWS Backup plan with cross-region DR copy |
| `dr-backup-exclude.sh` | Exclude tagged instances from backup selections |
| `dr-cleanup.sh` | Remove backups of stopped EC2 instances; release unattached EIPs |
| `dr-inventory.sh` | Generate a full resource inventory report for a region (EC2, RDS, S3, Lambda, DynamoDB, API Gateway, EKS, SQS, SNS, KMS, and more) |
| `dr-migration-status.sh` | Check overall DR readiness across all services |
| `dr-serverless-migrate.sh` | Migrate DynamoDB, Lambda, and API Gateway resources to the DR region |
| `rds-cross-region-replica.sh` | Create cross-region read replicas for RDS instances |
| `s3-cross-region-backup.sh` | Set up S3 cross-region replication and sync |

---

## Prerequisites

All scripts require:

- **AWS CLI v2** — [Installation guide](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- **jq** — JSON processor (`apt install jq` / `brew install jq`)
- **AWS credentials configured** — via environment variables, `~/.aws/credentials`, or an IAM role

Verify your setup:

```bash
aws sts get-caller-identity
jq --version
```

---

## Scripts

### dr-backup-manager.sh

All-in-one DR backup management tool with three sub-commands: **audit**, **cleanup**, and **create**.

**Documentation:** [docs/dr-backup-manager.md](docs/dr-backup-manager.md)

```bash
# Audit current backup state (read-only)
./dr-backup-manager.sh audit --region me-south-1 --dr-region eu-west-1

# Clean up wasteful backups and release unattached EIPs
./dr-backup-manager.sh cleanup --region me-south-1

# Create a DR backup plan
./dr-backup-manager.sh create \
  --plan-name "MyDRPlan" \
  --instance-ids "i-0123456789abcdef0 i-0fedcba9876543210" \
  --region me-south-1 \
  --dr-region eu-west-1
```

---

### dr-create-backup-plan.sh

Creates a new AWS Backup plan with daily snapshots in the source region and automatic cross-region copies to a DR vault.

**Documentation:** [docs/dr-create-backup-plan.md](docs/dr-create-backup-plan.md)

```bash
./dr-create-backup-plan.sh \
  --plan-name "DailyBackupToIreland" \
  --instance-ids "i-0123456789abcdef0" \
  --region me-south-1 \
  --dr-region eu-west-1 \
  --local-retention 3 \
  --dr-retention 30
```

---

### dr-backup-exclude.sh

Updates existing AWS Backup selections to exclude any EC2 instance tagged `backup-exclude=true`. Useful after running `dr-cleanup.sh` to tag stopped instances.

**Documentation:** [docs/dr-backup-exclude.md](docs/dr-backup-exclude.md)

```bash
./dr-backup-exclude.sh --region me-south-1
```

---

### dr-cleanup.sh

Identifies and removes wasteful AWS Backup jobs targeting stopped EC2 instances, and releases unattached Elastic IP addresses (EIPs) to reduce unnecessary costs.

**Documentation:** [docs/dr-cleanup.md](docs/dr-cleanup.md)

```bash
./dr-cleanup.sh --region me-south-1
```

---

### dr-inventory.sh

Scans a region and generates a comprehensive, timestamped inventory report covering VPCs, EC2 instances, RDS databases, S3 buckets, ELBs, Lambda functions, API Gateway, DynamoDB, ECS, EKS, ECR, SQS, SNS, ACM certificates, Secrets Manager, SSM Parameter Store, WAF, and KMS keys.

**Documentation:** [docs/dr-inventory.md](docs/dr-inventory.md)

```bash
SOURCE_REGION=me-south-1 ./dr-inventory.sh
```

The report is saved to a file named `dr-inventory-<account-id>-<region>-<timestamp>.txt`.

---

### dr-migration-status.sh

Checks the overall DR readiness of your AWS account by scanning AWS Backup plans, DR vaults, S3 replication, RDS read replicas, ECR replication, EC2 backup coverage, Route 53 health checks, and ACM certificates in the DR region.

**Documentation:** [docs/dr-migration-status.md](docs/dr-migration-status.md)

```bash
./dr-migration-status.sh --region me-south-1 --dr-region eu-west-1
```

---

### dr-serverless-migrate.sh

Audits and migrates serverless resources — DynamoDB tables (via Global Tables), Lambda functions and layers, and API Gateway REST/HTTP APIs — from the source region to the DR region.

**Documentation:** [docs/dr-serverless-migrate.md](docs/dr-serverless-migrate.md)

```bash
# Audit serverless resources (read-only)
./dr-serverless-migrate.sh audit

# Enable DynamoDB Global Tables (dry-run preview)
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 \
  ./dr-serverless-migrate.sh dynamodb --dry-run

# Deploy Lambda functions to DR region
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 \
  ./dr-serverless-migrate.sh lambda --skip-deprecated

# Migrate API Gateway to DR region
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 \
  ./dr-serverless-migrate.sh apigateway --dry-run

# Clean up orphaned API Gateway integrations
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 \
  ./dr-serverless-migrate.sh cleanup
```

---

### rds-cross-region-replica.sh

Discovers all RDS instances in a source region and interactively creates cross-region read replicas in a DR region. Handles encrypted instances (KMS key management), supports dry-run mode, and detects existing replicas.

**Documentation:** [docs/rds-cross-region-replica.md](docs/rds-cross-region-replica.md)

```bash
# Preview (dry-run)
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./rds-cross-region-replica.sh --dry-run

# Apply
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./rds-cross-region-replica.sh
```

---

### s3-cross-region-backup.sh

Discovers S3 buckets in the source region, creates corresponding backup buckets in the DR region, syncs existing objects, and sets up ongoing S3 Cross-Region Replication (CRR) rules.

**Documentation:** [docs/s3-cross-region-backup.md](docs/s3-cross-region-backup.md)

```bash
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./s3-cross-region-backup.sh
```

---

## IAM Permissions

The IAM principal running these scripts needs permissions across several services. A minimum set includes:

| Service | Actions Required |
|---------|-----------------|
| AWS Backup | `backup:*` (list, get, create, delete plans/vaults/selections) |
| EC2 | `ec2:DescribeInstances`, `ec2:DescribeAddresses`, `ec2:CreateTags`, `ec2:ReleaseAddress` |
| RDS | `rds:DescribeDBInstances`, `rds:CreateDBInstanceReadReplica` |
| S3 | `s3:*` (list buckets, get/put configuration, replication, sync) |
| IAM | `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:GetRole`, `iam:PassRole` |
| KMS | `kms:CreateKey`, `kms:DescribeKey`, `kms:CreateAlias` (for encrypted RDS) |
| DynamoDB | `dynamodb:ListTables`, `dynamodb:DescribeTable`, `dynamodb:UpdateTable` (for Global Tables) |
| Lambda | `lambda:ListFunctions`, `lambda:GetFunction`, `lambda:CreateFunction`, `lambda:ListLayers`, `lambda:PublishLayerVersion` |
| API Gateway | `apigateway:GET`, `apigateway:POST`, `apigatewayv2:*` |
| STS | `sts:GetCallerIdentity` |

For least-privilege setups, refer to each script's individual documentation in the `docs/` directory.

---

## Recommended Workflow

1. **Inventory your resources**
   ```bash
   SOURCE_REGION=me-south-1 ./dr-inventory.sh
   ```

2. **Check current DR status**
   ```bash
   ./dr-migration-status.sh --region me-south-1 --dr-region eu-west-1
   ```

3. **Clean up waste (optional)**
   ```bash
   ./dr-cleanup.sh --region me-south-1
   ```

4. **Set up EC2 backup plans**
   ```bash
   ./dr-backup-manager.sh create \
     --plan-name "ProdDR" \
     --instance-ids "i-0123456789abcdef0" \
     --region me-south-1 \
     --dr-region eu-west-1
   ```

5. **Exclude stopped instances from backups (optional)**
   ```bash
   ./dr-backup-exclude.sh --region me-south-1
   ```

6. **Set up RDS cross-region replicas**
   ```bash
   SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./rds-cross-region-replica.sh
   ```

7. **Migrate serverless resources (DynamoDB, Lambda, API Gateway)**
   ```bash
   SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./dr-serverless-migrate.sh audit
   SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./dr-serverless-migrate.sh dynamodb
   SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./dr-serverless-migrate.sh lambda
   SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./dr-serverless-migrate.sh apigateway
   ```

8. **Set up S3 cross-region replication**
   ```bash
   SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./s3-cross-region-backup.sh
   ```

9. **Verify overall DR readiness**
   ```bash
   ./dr-migration-status.sh --region me-south-1 --dr-region eu-west-1
   ```

---

## Default Region Configuration

All scripts default to:

| Variable | Default Value | Description |
|----------|--------------|-------------|
| `SOURCE_REGION` / `--region` | `me-south-1` | Primary AWS region (Bahrain) |
| `DEST_REGION` / `DR_REGION` / `--dr-region` | `eu-west-1` | DR AWS region (Ireland) |

Override the defaults using environment variables or command-line flags as shown in each script's usage section.
