# rds-cross-region-replica.sh

Discovers all RDS instances in a source region and interactively creates cross-region read replicas in a DR region for disaster recovery purposes.

## Overview

| Attribute | Value |
|-----------|-------|
| **File** | `rds-cross-region-replica.sh` |
| **Default source region** | `me-south-1` (Bahrain), or `$SOURCE_REGION` |
| **Default DR region** | `eu-west-1` (Ireland), or `$DEST_REGION` |
| **Default replica suffix** | `-dr-replica`, or `$REPLICA_SUFFIX` |
| **Requires** | AWS CLI v2, `jq` |

## Usage

```bash
./rds-cross-region-replica.sh [--dry-run]
```

Override regions via environment variables:

```bash
SOURCE_REGION=ap-southeast-1 DEST_REGION=eu-west-1 ./rds-cross-region-replica.sh
```

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview all actions without creating any replicas |

## Examples

### Preview (Dry-Run)

```bash
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./rds-cross-region-replica.sh --dry-run
```

### Apply

```bash
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 ./rds-cross-region-replica.sh
```

### Custom Replica Suffix

```bash
REPLICA_SUFFIX=-ireland-replica ./rds-cross-region-replica.sh
```

## What It Does

1. **Detects AWS identity** — Displays account ID and caller ARN.
2. **Prompts for region confirmation** — Allows overriding source and DR regions interactively.
3. **Validates region pair** — Exits if source and destination are the same.
4. **Discovers RDS instances** — Lists all DB instances in the source region with:
   - DB identifier, engine + version, instance class, storage
   - Multi-AZ status, encryption status, current state
5. **For each instance**, prompts whether to create a cross-region replica:
   - Skips instances that already have a replica with the expected name in the DR region
   - For **encrypted** instances: creates (or reuses) a KMS key in the DR region with an alias matching the source key alias
   - Creates the read replica with the same instance class and storage type
6. **Prints a summary** — Created, skipped (already exists), and failed counts.

## Replica Naming

Replicas are named `<source-db-identifier><REPLICA_SUFFIX>`:

| Source DB | Replica Name |
|-----------|-------------|
| `prod-mysql` | `prod-mysql-dr-replica` |
| `app-postgres` | `app-postgres-dr-replica` |

## Supported Engines

- MySQL
- PostgreSQL
- MariaDB
- Oracle
- SQL Server

## Encrypted Instance Handling

For KMS-encrypted RDS instances:

1. The script looks up the alias of the source KMS key.
2. In the DR region, it checks for an existing KMS key with the same alias.
3. If no matching key exists, it creates a new symmetric KMS key and assigns the alias.
4. The replica is created using this DR-region KMS key.

## IAM Permissions Required

```json
{
  "Effect": "Allow",
  "Action": [
    "rds:DescribeDBInstances",
    "rds:CreateDBInstanceReadReplica",
    "kms:DescribeKey",
    "kms:CreateKey",
    "kms:CreateAlias",
    "kms:ListAliases",
    "iam:CreateServiceLinkedRole",
    "sts:GetCallerIdentity"
  ],
  "Resource": "*"
}
```

## Notes

- Read replicas can only be created for DB instances in `available` state with automated backups enabled (backup retention > 0).
- Oracle and SQL Server read replicas have additional licensing and edition requirements — check AWS documentation.
- The script does **not** promote replicas to standalone instances. That is a separate DR failover step.
- Use `--dry-run` to safely validate what would happen before making any changes.
- Replica creation takes several minutes; the script does not wait for completion.
