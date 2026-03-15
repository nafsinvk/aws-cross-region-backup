# dr-serverless-migrate.sh

Audits and migrates serverless resources — DynamoDB tables, Lambda functions, and API Gateway APIs — from a source region to a DR region.

## Overview

| Attribute | Value |
|-----------|-------|
| **File** | `dr-serverless-migrate.sh` |
| **Default source region** | `me-south-1` (Bahrain), or `$SOURCE_REGION` |
| **Default DR region** | `eu-west-1` (Ireland), or `$DEST_REGION` |
| **Requires** | AWS CLI v2, `jq`, `curl` |

## Usage

```bash
./dr-serverless-migrate.sh <command> [options]
```

### Commands

| Command | Description |
|---------|-------------|
| `audit` | Read-only scan of DynamoDB, Lambda, and API Gateway resources |
| `dynamodb` | Enable DynamoDB Global Tables for the DR region |
| `lambda` | Export and deploy Lambda functions (and layers) to the DR region |
| `apigateway` | Export REST APIs and recreate HTTP APIs in the DR region |
| `cleanup` | Find and delete orphaned API Gateway integrations |

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview changes without making any modifications |
| `--skip-deprecated` | Skip Lambda functions with deprecated runtimes |
| `--region <region>` | Override source region (default: `me-south-1`) |
| `--dr-region <region>` | Override DR region (default: `eu-west-1`) |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SOURCE_REGION` | `me-south-1` | Primary AWS region |
| `DEST_REGION` | `eu-west-1` | DR AWS region |

## Examples

```bash
# Audit all serverless resources (read-only)
./dr-serverless-migrate.sh audit

# Preview DynamoDB Global Table setup (no changes)
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 \
  ./dr-serverless-migrate.sh dynamodb --dry-run

# Enable DynamoDB Global Tables for DR region
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 \
  ./dr-serverless-migrate.sh dynamodb

# Deploy Lambda functions to DR region (skip deprecated runtimes)
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 \
  ./dr-serverless-migrate.sh lambda --skip-deprecated

# Migrate API Gateway (dry run)
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 \
  ./dr-serverless-migrate.sh apigateway --dry-run

# Clean up orphaned API Gateway integrations
SOURCE_REGION=me-south-1 DEST_REGION=eu-west-1 \
  ./dr-serverless-migrate.sh cleanup
```

## Commands in Detail

### `audit`

Performs a **read-only** scan of all serverless resources in the source region and reports:

- **DynamoDB tables** — status, item count, size, billing mode, and whether a Global Table replica already exists in the DR region.
- **Lambda functions** — runtime, memory, timeout, code size, architecture, package type, and deprecated runtime warnings.
- **Lambda layers** — name, version, and compatible runtime.
- **REST APIs** (API Gateway v1) — API name, endpoint type, and stages.
- **HTTP APIs** (API Gateway v2) — API name, protocol, routes, integrations, and orphaned integration warnings.
- **Custom domain names** — domain, endpoint type.

A summary is printed at the end with next-step commands.

### `dynamodb`

Enables [DynamoDB Global Tables](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html) so each table replicates to the DR region. For each table the script:

1. Checks whether a replica already exists in the DR region (skips if so).
2. Warns if the table uses `PROVISIONED` billing and offers to switch to `PAY_PER_REQUEST` (required for Global Tables on some table versions).
3. Enables DynamoDB Streams if not already active (required for Global Tables).
4. Prompts for confirmation before creating the replica.
5. Polls until the replica reaches `ACTIVE` status.

### `lambda`

Migrates Lambda layers and functions from the source region to the DR region.

**Layers** are migrated first: each layer's ZIP is downloaded and re-published in the DR region.

**Functions** are processed one at a time:
- Deprecated runtimes are flagged (and can be skipped with `--skip-deprecated`).
- Container-image functions are skipped with instructions to replicate the ECR image first.
- Functions already present in the DR region are skipped.
- For each eligible function: the deployment package is downloaded, environment variables and layer ARNs (remapped to the DR region) are applied, and the function is created in the DR region.
- VPC-attached functions have their VPC config omitted with a warning (add after DR VPC is configured).

### `apigateway`

Migrates REST APIs (API Gateway v1) and HTTP APIs (API Gateway v2).

**REST APIs** are exported as OpenAPI 3.0 (OAS30) from the source stage and imported into the DR region. A deployment is created automatically for the same stage name.

**HTTP APIs** cannot be exported natively, so the script recreates them:
1. Creates a new HTTP API in the DR region with the same name and protocol.
2. For each route, looks up the source integration, remaps Lambda ARN region references, creates the integration in the DR region, and creates the route pointing to the new integration. Duplicate integrations across routes are deduplicated.
3. Creates a `$default` stage with auto-deploy enabled.

**Custom domain names** are listed with guidance: an ACM certificate must exist in the DR region before the domain can be recreated.

### `cleanup`

Scans HTTP APIs in both source and DR regions for orphaned integrations (integrations not referenced by any route). For each API with orphaned integrations:
- Displays the count and a sample of what the orphaned integrations point to.
- In dry-run mode, reports what would be deleted.
- Otherwise, prompts for confirmation and deletes the orphaned integrations.

Also checks the DR region for duplicate HTTP API names (created by multiple migration runs) and prints the `delete-api` commands to remove extras.

## Deprecated Runtimes

The following Lambda runtimes are flagged as deprecated and a suggested upgrade is shown:

| Deprecated runtime | Suggested replacement |
|--------------------|-----------------------|
| `nodejs14.x`, `nodejs16.x` | `nodejs20.x` or `nodejs22.x` |
| `python3.7`, `python3.8` | `python3.12` or `python3.13` |
| `dotnetcore3.1` | `dotnet8` |
| `ruby2.7` | `ruby3.3` |
| `java8` | `java21` |
| `go1.x` | `provided.al2023` (custom runtime) |

## IAM Permissions Required

```json
{
  "Effect": "Allow",
  "Action": [
    "dynamodb:ListTables",
    "dynamodb:DescribeTable",
    "dynamodb:UpdateTable",
    "lambda:ListFunctions",
    "lambda:GetFunction",
    "lambda:CreateFunction",
    "lambda:ListLayers",
    "lambda:GetLayerVersion",
    "lambda:PublishLayerVersion",
    "lambda:ListEventSourceMappings",
    "apigateway:GET",
    "apigateway:POST",
    "apigateway:PUT",
    "apigateway:DELETE",
    "apigatewayv2:GetApis",
    "apigatewayv2:CreateApi",
    "apigatewayv2:GetIntegrations",
    "apigatewayv2:CreateIntegration",
    "apigatewayv2:DeleteIntegration",
    "apigatewayv2:GetRoutes",
    "apigatewayv2:CreateRoute",
    "apigatewayv2:CreateStage",
    "iam:ListAccountAliases",
    "sts:GetCallerIdentity"
  ],
  "Resource": "*"
}
```

## Notes

- The `audit` command is entirely **read-only** — it makes no changes to any AWS resources.
- Lambda functions with **container images** (`PackageType: Image`) are skipped; set up ECR cross-region replication first, then create the function manually.
- Lambda functions with **VPC configuration** are deployed without the VPC config; add it after configuring the DR VPC.
- DynamoDB Global Tables require DynamoDB Streams to be enabled. The script enables streams automatically if needed.
- REST API export/import migrates the API structure only; authorizers, custom domain mappings, and stage variables may need manual reconfiguration.
- Run `audit` first to understand what exists before running migration commands.
