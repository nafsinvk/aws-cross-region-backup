# dr-inventory.sh

Scans an AWS region and generates a comprehensive, timestamped resource inventory report covering all critical infrastructure components.

## Overview

| Attribute | Value |
|-----------|-------|
| **File** | `dr-inventory.sh` |
| **Default region** | `me-south-1` (Bahrain), or `$SOURCE_REGION` |
| **Requires** | AWS CLI v2, `jq` |
| **Output** | Terminal + timestamped `.txt` report file |

## Usage

```bash
./dr-inventory.sh
```

The script prompts interactively for the region to scan. Override the default with the `SOURCE_REGION` environment variable:

```bash
SOURCE_REGION=eu-west-1 ./dr-inventory.sh
```

## Report Output

The inventory is saved to a file in the current directory:

```
dr-inventory-<account-id>[-<account-alias>]-<region>-<YYYYMMDD-HHMMSS>.txt
```

Example:

```
dr-inventory-123456789012-myaccount-me-south-1-20240315-143022.txt
```

All output is simultaneously printed to the terminal and written to the report file.

## What It Scans

| Section | Resources |
|---------|-----------|
| **1. VPC & Networking** | VPCs, Subnets, Security Groups, Route Tables, Internet Gateways, NAT Gateways |
| **2. EC2 Instances** | All instances with state, type, name, key pair, and private IP |
| **3. EBS Volumes** | All volumes with state, size, type, encryption status |
| **4. Elastic IPs** | All EIPs with association status |
| **5. RDS Databases** | DB instances with engine, class, storage, MultiAZ, encryption |
| **6. S3 Buckets** | All buckets with region, versioning, replication, and encryption status |
| **7. Load Balancers** | ALBs, NLBs (v2), and classic ELBs |
| **8. ECS** | Clusters and running task/service counts |
| **9. Lambda** | Functions with runtime and memory |
| **10. ECR** | Container repositories |
| **11. CloudFront** | Distributions with origin and status |
| **12. Route 53** | Hosted zones and record set counts |
| **13. ACM Certificates** | SSL/TLS certificates with domain, status, and expiry |
| **14. IAM** | Users, groups, roles, policies (summary counts) |
| **15. Secrets Manager** | Secret names (not values) |
| **16. AWS Backup** | Backup plans, selections, and vaults |

## IAM Permissions Required

The script performs **read-only** operations. Required permissions include:

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:Describe*",
    "rds:DescribeDBInstances",
    "s3:ListAllMyBuckets",
    "s3:GetBucketLocation",
    "s3:GetBucketVersioning",
    "s3:GetBucketReplication",
    "s3:GetBucketEncryption",
    "elasticloadbalancing:DescribeLoadBalancers",
    "ecs:ListClusters",
    "ecs:DescribeClusters",
    "lambda:ListFunctions",
    "ecr:DescribeRepositories",
    "cloudfront:ListDistributions",
    "route53:ListHostedZones",
    "route53:GetHostedZone",
    "acm:ListCertificates",
    "acm:DescribeCertificate",
    "iam:ListUsers",
    "iam:ListGroups",
    "iam:ListRoles",
    "iam:ListPolicies",
    "secretsmanager:ListSecrets",
    "backup:ListBackupPlans",
    "backup:ListBackupSelections",
    "backup:ListBackupVaults",
    "sts:GetCallerIdentity",
    "iam:ListAccountAliases",
    "organizations:DescribeAccount"
  ],
  "Resource": "*"
}
```

## Notes

- The script is entirely **read-only** — it makes no changes to any AWS resources.
- Secret **values** are never retrieved; only secret names are listed.
- The report file can be used as a baseline before a DR migration, for compliance audits, or for cost reviews.
- For large accounts, the scan may take several minutes depending on the number of resources.
