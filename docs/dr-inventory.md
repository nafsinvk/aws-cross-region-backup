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
| **1. VPC & Networking** | VPCs, Subnets, Security Groups, NACLs, Route Tables, Internet Gateways, NAT Gateways |
| **2. Elastic IPs** | All EIPs with allocation and association status |
| **3. EC2 Instances & Auto Scaling** | Instances, AMIs, EBS volumes, EBS snapshots, Launch Templates, Auto Scaling Groups, Scaling Policies |
| **4. Load Balancers & Target Groups** | ALBs, NLBs, classic ELBs, Target Groups |
| **5. S3 Buckets** | Buckets in the scanned region with object count, size, versioning, and replication status |
| **6. RDS Instances** | DB instances, Read Replicas, Subnet Groups, Automated Backups, Parameter Groups |
| **7. Lambda Functions** | Functions with runtime, memory, timeout, and code size; Lambda Layers; Event Source Mappings |
| **8. API Gateway** | REST APIs, HTTP APIs (v2), Custom Domain Names |
| **9. DynamoDB Tables** | Tables with status, item count, size, billing mode, and Global Table version |
| **10. ECS / EKS / ECR** | ECS Clusters, ECS Services, ECS Task Definitions, EKS Clusters, ECR Repositories, ECR replication config |
| **11. SQS & SNS** | SQS queues with visibility/retention settings; SNS topics with subscription counts |
| **12. Security & Config Services** | ACM certificates, Secrets Manager secrets, SSM Parameter Store, WAF Web ACLs, IAM instance profiles, customer-managed KMS keys |

## IAM Permissions Required

The script performs **read-only** operations. Required permissions include:

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:Describe*",
    "autoscaling:DescribeAutoScalingGroups",
    "autoscaling:DescribePolicies",
    "elasticloadbalancing:DescribeLoadBalancers",
    "elasticloadbalancing:DescribeTargetGroups",
    "s3:ListAllMyBuckets",
    "s3:GetBucketLocation",
    "s3:GetBucketVersioning",
    "s3:GetBucketReplication",
    "s3:ListBucket",
    "rds:DescribeDBInstances",
    "rds:DescribeDBSubnetGroups",
    "rds:DescribeDBInstanceAutomatedBackups",
    "rds:DescribeDBParameterGroups",
    "lambda:ListFunctions",
    "lambda:ListLayers",
    "lambda:ListEventSourceMappings",
    "apigateway:GET",
    "apigatewayv2:GetApis",
    "apigatewayv2:GetIntegrations",
    "apigatewayv2:GetRoutes",
    "dynamodb:ListTables",
    "dynamodb:DescribeTable",
    "ecs:ListClusters",
    "ecs:ListServices",
    "ecs:DescribeServices",
    "ecs:ListTasks",
    "ecs:ListTaskDefinitionFamilies",
    "eks:ListClusters",
    "eks:DescribeCluster",
    "ecr:DescribeRepositories",
    "ecr:ListImages",
    "ecr:DescribeRegistry",
    "sqs:ListQueues",
    "sqs:GetQueueAttributes",
    "sns:ListTopics",
    "sns:ListSubscriptionsByTopic",
    "acm:ListCertificates",
    "secretsmanager:ListSecrets",
    "ssm:DescribeParameters",
    "wafv2:ListWebACLs",
    "iam:ListInstanceProfiles",
    "kms:ListKeys",
    "kms:DescribeKey",
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
- SSM Parameter Store parameter values are never retrieved; only names, types, and versions are listed.
- S3 bucket listings may take extra time for buckets with large numbers of objects.
- EBS snapshots and AMIs are limited to the 20 most recent entries to keep the report concise.
- The report file can be used as a baseline before a DR migration, for compliance audits, or for cost reviews.
- For large accounts, the scan may take several minutes depending on the number of resources.
