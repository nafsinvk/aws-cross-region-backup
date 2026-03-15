#!/bin/bash
set -euo pipefail

# ============================================================
# AWS Cross-Region DR Inventory Script
# ============================================================
# Scans the source region for all critical resources and
# generates a comprehensive inventory report.
# ============================================================

SOURCE_REGION="${SOURCE_REGION:-me-south-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "\n${CYAN}==>${NC} ${BOLD}$*${NC}"; }
divider()     { echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"; }

# ── Pre-flight ──────────────────────────────────────────────
command -v aws >/dev/null 2>&1 || { log_error "AWS CLI not found."; exit 1; }
command -v jq >/dev/null 2>&1  || { log_error "jq not found."; exit 1; }

echo ""
divider
echo -e "${BOLD}  AWS RESOURCE INVENTORY${NC}"
divider

log_step "Detecting AWS identity..."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "")
if [[ -z "$ACCOUNT_ALIAS" || "$ACCOUNT_ALIAS" == "None" ]]; then
    # Try org account name as fallback
    ACCOUNT_ALIAS=$(aws organizations describe-account --account-id "$ACCOUNT_ID" \
        --query 'Account.Name' --output text 2>/dev/null || echo "")
fi
ACCOUNT_LABEL="${ACCOUNT_ALIAS:-$ACCOUNT_ID}"
log_info "Account : $ACCOUNT_ID"
[[ -n "$ACCOUNT_ALIAS" && "$ACCOUNT_ALIAS" != "None" ]] && log_info "Name    : $ACCOUNT_ALIAS"
log_info "Identity: $CALLER_ARN"

read -rp "Region to scan [${SOURCE_REGION}]: " input
SOURCE_REGION="${input:-$SOURCE_REGION}"

# Build report filename with account info
REPORT_FILE="dr-inventory-${ACCOUNT_ID}"
[[ -n "$ACCOUNT_ALIAS" && "$ACCOUNT_ALIAS" != "None" ]] && REPORT_FILE="${REPORT_FILE}-${ACCOUNT_ALIAS// /-}"
REPORT_FILE="${REPORT_FILE}-${SOURCE_REGION}-$(date +%Y%m%d-%H%M%S).txt"

# Tee all output to both terminal and report file
exec > >(tee -a "$REPORT_FILE") 2>&1

echo ""
log_info "Scanning Region: $SOURCE_REGION"
log_info "Report file    : $REPORT_FILE"
divider

# ════════════════════════════════════════════════════════════
# 1. VPC & NETWORKING
# ════════════════════════════════════════════════════════════
log_step "1. VPC & NETWORKING"

echo -e "\n  ${BOLD}VPCs:${NC}"
VPC_IDS=$(aws ec2 describe-vpcs --region "$SOURCE_REGION" \
    --query 'Vpcs[].VpcId' --output text 2>/dev/null || echo "")
if [[ -n "$VPC_IDS" && "$VPC_IDS" != "None" ]]; then
    for vpc in $VPC_IDS; do
        vpc_name=$(aws ec2 describe-vpcs --region "$SOURCE_REGION" --vpc-ids "$vpc" \
            --query 'Vpcs[0].Tags[?Key==`Name`].Value' --output text 2>/dev/null || echo "N/A")
        vpc_cidr=$(aws ec2 describe-vpcs --region "$SOURCE_REGION" --vpc-ids "$vpc" \
            --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null || echo "N/A")
        echo "    - $vpc | Name: $vpc_name | CIDR: $vpc_cidr"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Subnets:${NC}"
SUBNETS=$(aws ec2 describe-subnets --region "$SOURCE_REGION" \
    --query 'Subnets[].[SubnetId,VpcId,CidrBlock,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$SUBNETS" ]]; then
    echo "$SUBNETS" | while IFS=$'\t' read -r sid vid cidr az name; do
        echo "    - $sid | VPC: $vid | CIDR: $cidr | AZ: $az | Name: ${name:-N/A}"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Security Groups:${NC}"
SGS=$(aws ec2 describe-security-groups --region "$SOURCE_REGION" \
    --query 'SecurityGroups[].[GroupId,GroupName,VpcId,Description]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$SGS" ]]; then
    SG_COUNT=$(echo "$SGS" | wc -l | tr -d ' ')
    echo "$SGS" | while IFS=$'\t' read -r gid gname vid desc; do
        echo "    - $gid | $gname | VPC: $vid"
    done
    echo "    Total: $SG_COUNT security group(s)"
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}NACLs:${NC}"
NACLS=$(aws ec2 describe-network-acls --region "$SOURCE_REGION" \
    --query 'NetworkAcls[].[NetworkAclId,VpcId,IsDefault]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$NACLS" ]]; then
    echo "$NACLS" | while IFS=$'\t' read -r nid vid is_default; do
        echo "    - $nid | VPC: $vid | Default: $is_default"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Route Tables:${NC}"
RTS=$(aws ec2 describe-route-tables --region "$SOURCE_REGION" \
    --query 'RouteTables[].[RouteTableId,VpcId,Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$RTS" ]]; then
    echo "$RTS" | while IFS=$'\t' read -r rtid vid name; do
        echo "    - $rtid | VPC: $vid | Name: ${name:-N/A}"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}NAT Gateways:${NC}"
NATS=$(aws ec2 describe-nat-gateways --region "$SOURCE_REGION" \
    --filter "Name=state,Values=available" \
    --query 'NatGateways[].[NatGatewayId,VpcId,SubnetId,State]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$NATS" && "$NATS" != "None" ]]; then
    echo "$NATS" | while IFS=$'\t' read -r nid vid sid state; do
        echo "    - $nid | VPC: $vid | Subnet: $sid | State: $state"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Internet Gateways:${NC}"
IGWS=$(aws ec2 describe-internet-gateways --region "$SOURCE_REGION" \
    --query 'InternetGateways[].[InternetGatewayId,Attachments[0].VpcId]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$IGWS" && "$IGWS" != "None" ]]; then
    echo "$IGWS" | while IFS=$'\t' read -r igwid vid; do
        echo "    - $igwid | VPC: ${vid:-detached}"
    done
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 2. ELASTIC IPs
# ════════════════════════════════════════════════════════════
log_step "2. ELASTIC IPs"

EIPS=$(aws ec2 describe-addresses --region "$SOURCE_REGION" \
    --query 'Addresses[].[PublicIp,AllocationId,InstanceId,AssociationId,Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$EIPS" && "$EIPS" != "None" ]]; then
    echo "$EIPS" | while IFS=$'\t' read -r ip alloc inst assoc name; do
        echo "    - $ip | Alloc: $alloc | Instance: ${inst:-unattached} | Name: ${name:-N/A}"
    done
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 3. EC2 INSTANCES & AUTO SCALING
# ════════════════════════════════════════════════════════════
log_step "3. EC2 INSTANCES & AUTO SCALING"

echo -e "\n  ${BOLD}EC2 Instances:${NC}"
EC2_INSTANCES=$(aws ec2 describe-instances --region "$SOURCE_REGION" \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,SubnetId,Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$EC2_INSTANCES" && "$EC2_INSTANCES" != "None" ]]; then
    echo "$EC2_INSTANCES" | while IFS=$'\t' read -r iid itype state subnet name; do
        echo "    - $iid | $itype | $state | Subnet: ${subnet:-N/A} | Name: ${name:-N/A}"
    done
    EC2_COUNT=$(echo "$EC2_INSTANCES" | wc -l | tr -d ' ')
    echo "    Total: $EC2_COUNT instance(s)"
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}AMIs (owned by this account):${NC}"
AMIS=$(aws ec2 describe-images --region "$SOURCE_REGION" --owners self \
    --query 'Images[].[ImageId,Name,State,CreationDate]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$AMIS" && "$AMIS" != "None" ]]; then
    echo "$AMIS" | sort -t$'\t' -k4 -r | head -20 | while IFS=$'\t' read -r aid aname state created; do
        echo "    - $aid | $aname | $state | $created"
    done
    AMI_COUNT=$(echo "$AMIS" | wc -l | tr -d ' ')
    echo "    Total: $AMI_COUNT AMI(s) (showing latest 20)"
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}EBS Volumes:${NC}"
EBS=$(aws ec2 describe-volumes --region "$SOURCE_REGION" \
    --query 'Volumes[].[VolumeId,Size,VolumeType,State,Attachments[0].InstanceId]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$EBS" && "$EBS" != "None" ]]; then
    echo "$EBS" | while IFS=$'\t' read -r vid size vtype state inst; do
        echo "    - $vid | ${size}GB | $vtype | $state | Instance: ${inst:-detached}"
    done
    EBS_COUNT=$(echo "$EBS" | wc -l | tr -d ' ')
    echo "    Total: $EBS_COUNT volume(s)"
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}EBS Snapshots (owned by this account):${NC}"
SNAPSHOTS=$(aws ec2 describe-snapshots --region "$SOURCE_REGION" --owner-ids self \
    --query 'Snapshots[].[SnapshotId,VolumeId,VolumeSize,State,StartTime,Description]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$SNAPSHOTS" && "$SNAPSHOTS" != "None" ]]; then
    SNAP_COUNT=$(echo "$SNAPSHOTS" | wc -l | tr -d ' ')
    echo "$SNAPSHOTS" | sort -t$'\t' -k5 -r | head -20 | while IFS=$'\t' read -r sid vid size state start desc; do
        echo "    - $sid | Vol: ${vid:-N/A} | ${size}GB | $state | $start"
    done
    echo "    Total: $SNAP_COUNT snapshot(s) (showing latest 20)"
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Launch Templates:${NC}"
LTS=$(aws ec2 describe-launch-templates --region "$SOURCE_REGION" \
    --query 'LaunchTemplates[].[LaunchTemplateId,LaunchTemplateName,LatestVersionNumber]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$LTS" && "$LTS" != "None" ]]; then
    echo "$LTS" | while IFS=$'\t' read -r ltid ltname ltver; do
        echo "    - $ltid | $ltname | Latest Version: $ltver"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Auto Scaling Groups:${NC}"
ASGS=$(aws autoscaling describe-auto-scaling-groups --region "$SOURCE_REGION" \
    --query 'AutoScalingGroups[].[AutoScalingGroupName,MinSize,MaxSize,DesiredCapacity,LaunchTemplate.LaunchTemplateName]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$ASGS" && "$ASGS" != "None" ]]; then
    echo "$ASGS" | while IFS=$'\t' read -r aname amin amax adesired alt; do
        echo "    - $aname | Min: $amin | Max: $amax | Desired: $adesired | LT: ${alt:-N/A}"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Scaling Policies:${NC}"
POLICIES=$(aws autoscaling describe-policies --region "$SOURCE_REGION" \
    --query 'ScalingPolicies[].[PolicyName,AutoScalingGroupName,PolicyType,TargetTrackingConfiguration.PredefinedMetricSpecification.PredefinedMetricType]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$POLICIES" && "$POLICIES" != "None" ]]; then
    echo "$POLICIES" | while IFS=$'\t' read -r pname asg ptype metric; do
        echo "    - $pname | ASG: $asg | Type: $ptype | Metric: ${metric:-N/A}"
    done
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 4. ELB / ALB / NLB & TARGET GROUPS
# ════════════════════════════════════════════════════════════
log_step "4. LOAD BALANCERS & TARGET GROUPS"

echo -e "\n  ${BOLD}ALB / NLB:${NC}"
LBS=$(aws elbv2 describe-load-balancers --region "$SOURCE_REGION" \
    --query 'LoadBalancers[].[LoadBalancerName,Type,Scheme,DNSName,State.Code]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$LBS" && "$LBS" != "None" ]]; then
    echo "$LBS" | while IFS=$'\t' read -r lbname lbtype scheme dns state; do
        echo "    - $lbname | $lbtype | $scheme | $state"
        echo "      DNS: $dns"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Classic Load Balancers:${NC}"
CLBS=$(aws elb describe-load-balancers --region "$SOURCE_REGION" \
    --query 'LoadBalancerDescriptions[].[LoadBalancerName,DNSName,Scheme]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$CLBS" && "$CLBS" != "None" ]]; then
    echo "$CLBS" | while IFS=$'\t' read -r name dns scheme; do
        echo "    - $name | $scheme | DNS: $dns"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Target Groups:${NC}"
TGS=$(aws elbv2 describe-target-groups --region "$SOURCE_REGION" \
    --query 'TargetGroups[].[TargetGroupName,Protocol,Port,TargetType,VpcId]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$TGS" && "$TGS" != "None" ]]; then
    echo "$TGS" | while IFS=$'\t' read -r tgname proto port ttype vid; do
        echo "    - $tgname | $proto:$port | Type: $ttype | VPC: $vid"
    done
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 5. S3 BUCKETS
# ════════════════════════════════════════════════════════════
log_step "5. S3 BUCKETS (in ${SOURCE_REGION})"

ALL_BUCKETS=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null || echo "")
S3_COUNT=0
if [[ -n "$ALL_BUCKETS" ]]; then
    for bucket in $ALL_BUCKETS; do
        region=$(aws s3api get-bucket-location --bucket "$bucket" \
            --query 'LocationConstraint' --output text 2>/dev/null || true)
        [[ "$region" == "None" ]] && region="us-east-1"
        if [[ "$region" == "$SOURCE_REGION" ]]; then
            size_info=$(aws s3 ls "s3://${bucket}" --recursive --summarize 2>/dev/null | tail -2)
            obj_count=$(echo "$size_info" | grep "Total Objects:" | awk '{print $3}')
            total_size=$(echo "$size_info" | grep "Total Size:" | awk '{print $3}')
            size_hr=$(numfmt --to=iec "$total_size" 2>/dev/null || echo "${total_size:-0} bytes")
            versioning=$(aws s3api get-bucket-versioning --bucket "$bucket" \
                --query 'Status' --output text 2>/dev/null || echo "None")
            replication=$(aws s3api get-bucket-replication --bucket "$bucket" \
                --query 'ReplicationConfiguration.Rules[0].Status' --output text 2>/dev/null || echo "None")
            echo "    - $bucket | Objects: ${obj_count:-0} | Size: $size_hr | Versioning: $versioning | Replication: $replication"
            S3_COUNT=$((S3_COUNT + 1))
        fi
    done
    echo "    Total: $S3_COUNT bucket(s) in ${SOURCE_REGION}"
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 6. RDS INSTANCES
# ════════════════════════════════════════════════════════════
log_step "6. RDS INSTANCES"

echo -e "\n  ${BOLD}DB Instances:${NC}"
RDS_INSTANCES=$(aws rds describe-db-instances --region "$SOURCE_REGION" \
    --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass,Engine,EngineVersion,DBInstanceStatus,MultiAZ,StorageEncrypted,AllocatedStorage]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$RDS_INSTANCES" && "$RDS_INSTANCES" != "None" ]]; then
    echo "$RDS_INSTANCES" | while IFS=$'\t' read -r dbid dbclass engine ver status multiaz encrypted storage; do
        echo "    - $dbid"
        echo "      Engine: $engine $ver | Class: $dbclass | Storage: ${storage}GB"
        echo "      Status: $status | MultiAZ: $multiaz | Encrypted: $encrypted"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}RDS Read Replicas:${NC}"
RDS_REPLICAS=$(aws rds describe-db-instances --region "$SOURCE_REGION" \
    --query 'DBInstances[?ReadReplicaSourceDBInstanceIdentifier!=`null`].[DBInstanceIdentifier,ReadReplicaSourceDBInstanceIdentifier,DBInstanceStatus]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$RDS_REPLICAS" && "$RDS_REPLICAS" != "None" ]]; then
    echo "$RDS_REPLICAS" | while IFS=$'\t' read -r rid src status; do
        echo "    - $rid | Source: $src | Status: $status"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}RDS Subnet Groups:${NC}"
RDS_SUBNETS=$(aws rds describe-db-subnet-groups --region "$SOURCE_REGION" \
    --query 'DBSubnetGroups[].[DBSubnetGroupName,VpcId,DBSubnetGroupDescription]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$RDS_SUBNETS" && "$RDS_SUBNETS" != "None" ]]; then
    echo "$RDS_SUBNETS" | while IFS=$'\t' read -r sgname vid desc; do
        echo "    - $sgname | VPC: $vid | $desc"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}RDS Automated Backups:${NC}"
RDS_BACKUPS=$(aws rds describe-db-instance-automated-backups --region "$SOURCE_REGION" \
    --query 'DBInstanceAutomatedBackups[].[DBInstanceIdentifier,Status,BackupRetentionPeriod]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$RDS_BACKUPS" && "$RDS_BACKUPS" != "None" ]]; then
    echo "$RDS_BACKUPS" | while IFS=$'\t' read -r dbid status retention; do
        echo "    - $dbid | Status: $status | Retention: ${retention} days"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}RDS Parameter Groups:${NC}"
RDS_PGS=$(aws rds describe-db-parameter-groups --region "$SOURCE_REGION" \
    --query 'DBParameterGroups[?DBParameterGroupFamily!=`null`].[DBParameterGroupName,DBParameterGroupFamily,Description]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$RDS_PGS" && "$RDS_PGS" != "None" ]]; then
    echo "$RDS_PGS" | while IFS=$'\t' read -r pgname family desc; do
        echo "    - $pgname | Family: $family"
    done
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 7. LAMBDA FUNCTIONS
# ════════════════════════════════════════════════════════════
log_step "7. LAMBDA FUNCTIONS"

LAMBDAS=$(aws lambda list-functions --region "$SOURCE_REGION" \
    --query 'Functions[].[FunctionName,Runtime,MemorySize,Timeout,Handler,CodeSize]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$LAMBDAS" && "$LAMBDAS" != "None" ]]; then
    echo "$LAMBDAS" | while IFS=$'\t' read -r fname runtime mem timeout handler codesize; do
        size_hr=$(numfmt --to=iec "$codesize" 2>/dev/null || echo "${codesize} bytes")
        echo "    - $fname"
        echo "      Runtime: $runtime | Memory: ${mem}MB | Timeout: ${timeout}s | Code: $size_hr"
    done
    LAMBDA_COUNT=$(echo "$LAMBDAS" | wc -l | tr -d ' ')
    echo "    Total: $LAMBDA_COUNT function(s)"
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Lambda Layers:${NC}"
LAYERS=$(aws lambda list-layers --region "$SOURCE_REGION" \
    --query 'Layers[].[LayerName,LatestMatchingVersion.Version,LatestMatchingVersion.CompatibleRuntimes[0]]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$LAYERS" && "$LAYERS" != "None" ]]; then
    echo "$LAYERS" | while IFS=$'\t' read -r lname lver lruntime; do
        echo "    - $lname | Version: $lver | Runtime: ${lruntime:-N/A}"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Lambda Event Source Mappings:${NC}"
ESM=$(aws lambda list-event-source-mappings --region "$SOURCE_REGION" \
    --query 'EventSourceMappings[].[FunctionArn,EventSourceArn,State]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$ESM" && "$ESM" != "None" ]]; then
    echo "$ESM" | while IFS=$'\t' read -r farn esarn state; do
        fname=$(echo "$farn" | awk -F: '{print $NF}')
        echo "    - $fname -> $esarn | $state"
    done
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 8. API GATEWAY
# ════════════════════════════════════════════════════════════
log_step "8. API GATEWAY"

echo -e "\n  ${BOLD}REST APIs:${NC}"
REST_APIS=$(aws apigateway get-rest-apis --region "$SOURCE_REGION" \
    --query 'items[].[id,name,description]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$REST_APIS" && "$REST_APIS" != "None" ]]; then
    echo "$REST_APIS" | while IFS=$'\t' read -r aid aname adesc; do
        echo "    - $aid | $aname | ${adesc:-No description}"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}HTTP APIs (API Gateway v2):${NC}"
HTTP_APIS=$(aws apigatewayv2 get-apis --region "$SOURCE_REGION" \
    --query 'Items[].[ApiId,Name,ProtocolType]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$HTTP_APIS" && "$HTTP_APIS" != "None" ]]; then
    echo "$HTTP_APIS" | while IFS=$'\t' read -r aid aname proto; do
        echo "    - $aid | $aname | $proto"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}API Gateway Custom Domain Names:${NC}"
DOMAINS=$(aws apigateway get-domain-names --region "$SOURCE_REGION" \
    --query 'items[].[domainName,certificateArn,endpointConfiguration.types[0]]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$DOMAINS" && "$DOMAINS" != "None" ]]; then
    echo "$DOMAINS" | while IFS=$'\t' read -r dname cert etype; do
        echo "    - $dname | Endpoint: ${etype:-N/A}"
    done
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 9. DYNAMODB TABLES
# ════════════════════════════════════════════════════════════
log_step "9. DYNAMODB TABLES"

DDB_TABLES=$(aws dynamodb list-tables --region "$SOURCE_REGION" \
    --query 'TableNames[]' --output text 2>/dev/null || echo "")
if [[ -n "$DDB_TABLES" && "$DDB_TABLES" != "None" ]]; then
    for table in $DDB_TABLES; do
        table_info=$(aws dynamodb describe-table --region "$SOURCE_REGION" \
            --table-name "$table" \
            --query 'Table.[TableStatus,ItemCount,TableSizeBytes,BillingModeSummary.BillingMode,GlobalTableVersion]' \
            --output text 2>/dev/null || echo "N/A")
        IFS=$'\t' read -r status items size billing gtver <<< "$table_info"
        size_hr=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size:-0} bytes")
        echo "    - $table | Status: $status | Items: $items | Size: $size_hr | Billing: ${billing:-PROVISIONED} | GlobalTable: ${gtver:-No}"
    done
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 10. ECS / EKS / ECR
# ════════════════════════════════════════════════════════════
log_step "10. ECS / EKS / ECR"

echo -e "\n  ${BOLD}ECS Clusters:${NC}"
ECS_CLUSTERS=$(aws ecs list-clusters --region "$SOURCE_REGION" \
    --query 'clusterArns[]' --output text 2>/dev/null || echo "")
if [[ -n "$ECS_CLUSTERS" && "$ECS_CLUSTERS" != "None" ]]; then
    for cluster_arn in $ECS_CLUSTERS; do
        cluster_name=$(echo "$cluster_arn" | awk -F/ '{print $NF}')
        svc_count=$(aws ecs list-services --region "$SOURCE_REGION" --cluster "$cluster_name" \
            --query 'serviceArns' --output text 2>/dev/null | wc -w | tr -d ' ')
        task_count=$(aws ecs list-tasks --region "$SOURCE_REGION" --cluster "$cluster_name" \
            --query 'taskArns' --output text 2>/dev/null | wc -w | tr -d ' ')
        echo "    - $cluster_name | Services: $svc_count | Running Tasks: $task_count"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}ECS Services:${NC}"
if [[ -n "$ECS_CLUSTERS" && "$ECS_CLUSTERS" != "None" ]]; then
    has_services=false
    for cluster_arn in $ECS_CLUSTERS; do
        cluster_name=$(echo "$cluster_arn" | awk -F/ '{print $NF}')
        SERVICES=$(aws ecs list-services --region "$SOURCE_REGION" --cluster "$cluster_name" \
            --query 'serviceArns[]' --output text 2>/dev/null || echo "")
        if [[ -n "$SERVICES" && "$SERVICES" != "None" ]]; then
            has_services=true
            for svc_arn in $SERVICES; do
                svc_info=$(aws ecs describe-services --region "$SOURCE_REGION" \
                    --cluster "$cluster_name" --services "$svc_arn" \
                    --query 'services[0].[serviceName,desiredCount,runningCount,launchType]' \
                    --output text 2>/dev/null || echo "")
                IFS=$'\t' read -r sname desired running launch <<< "$svc_info"
                echo "    - $cluster_name/$sname | Desired: $desired | Running: $running | Launch: ${launch:-N/A}"
            done
        fi
    done
    if [[ "$has_services" == "false" ]]; then
        echo "    (none)"
    fi
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}ECS Task Definitions:${NC}"
TASK_DEFS=$(aws ecs list-task-definition-families --region "$SOURCE_REGION" \
    --status ACTIVE --query 'families[]' --output text 2>/dev/null || echo "")
if [[ -n "$TASK_DEFS" && "$TASK_DEFS" != "None" ]]; then
    for td in $TASK_DEFS; do
        echo "    - $td"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}EKS Clusters:${NC}"
EKS_CLUSTERS=$(aws eks list-clusters --region "$SOURCE_REGION" \
    --query 'clusters[]' --output text 2>/dev/null || echo "")
if [[ -n "$EKS_CLUSTERS" && "$EKS_CLUSTERS" != "None" ]]; then
    for eks in $EKS_CLUSTERS; do
        eks_info=$(aws eks describe-cluster --region "$SOURCE_REGION" --name "$eks" \
            --query 'cluster.[version,status,platformVersion]' \
            --output text 2>/dev/null || echo "")
        IFS=$'\t' read -r ver status platform <<< "$eks_info"
        echo "    - $eks | K8s: $ver | Status: $status | Platform: $platform"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}ECR Repositories:${NC}"
ECR_REPOS=$(aws ecr describe-repositories --region "$SOURCE_REGION" \
    --query 'repositories[].[repositoryName,repositoryUri,imageTagMutability]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$ECR_REPOS" && "$ECR_REPOS" != "None" ]]; then
    echo "$ECR_REPOS" | while IFS=$'\t' read -r rname ruri rtag; do
        img_count=$(aws ecr list-images --region "$SOURCE_REGION" --repository-name "$rname" \
            --query 'imageIds' --output text 2>/dev/null | wc -w | tr -d ' ')
        echo "    - $rname | Images: $img_count | Mutability: $rtag"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}ECR Replication Configuration:${NC}"
ECR_REPL=$(aws ecr describe-registry --region "$SOURCE_REGION" \
    --query 'replicationConfiguration.rules[].destinations[].[region,registryId]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$ECR_REPL" && "$ECR_REPL" != "None" ]]; then
    echo "$ECR_REPL" | while IFS=$'\t' read -r rregion rid; do
        echo "    - Replicating to: $rregion | Registry: $rid"
    done
else
    echo "    (no cross-region replication configured)"
fi

# ════════════════════════════════════════════════════════════
# 11. SQS & SNS
# ════════════════════════════════════════════════════════════
log_step "11. SQS & SNS"

echo -e "\n  ${BOLD}SQS Queues:${NC}"
SQS_QUEUES=$(aws sqs list-queues --region "$SOURCE_REGION" \
    --query 'QueueUrls[]' --output text 2>/dev/null || echo "")
if [[ -n "$SQS_QUEUES" && "$SQS_QUEUES" != "None" ]]; then
    for queue_url in $SQS_QUEUES; do
        qname=$(echo "$queue_url" | awk -F/ '{print $NF}')
        attrs=$(aws sqs get-queue-attributes --region "$SOURCE_REGION" \
            --queue-url "$queue_url" --attribute-names All \
            --query 'Attributes.[VisibilityTimeout,MessageRetentionPeriod,DelaySeconds,ApproximateNumberOfMessages]' \
            --output text 2>/dev/null || echo "")
        IFS=$'\t' read -r vis ret delay msgs <<< "$attrs"
        echo "    - $qname | Visibility: ${vis}s | Retention: ${ret}s | Delay: ${delay}s | Messages: ${msgs:-0}"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}SNS Topics:${NC}"
SNS_TOPICS=$(aws sns list-topics --region "$SOURCE_REGION" \
    --query 'Topics[].TopicArn' --output text 2>/dev/null || echo "")
if [[ -n "$SNS_TOPICS" && "$SNS_TOPICS" != "None" ]]; then
    for topic_arn in $SNS_TOPICS; do
        tname=$(echo "$topic_arn" | awk -F: '{print $NF}')
        sub_count=$(aws sns list-subscriptions-by-topic --region "$SOURCE_REGION" \
            --topic-arn "$topic_arn" --query 'Subscriptions' --output text 2>/dev/null | wc -l | tr -d ' ')
        echo "    - $tname | Subscriptions: $sub_count"
    done
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# 12. SECURITY & CONFIG SERVICES
# ════════════════════════════════════════════════════════════
log_step "12. SECURITY & CONFIG SERVICES"

echo -e "\n  ${BOLD}ACM Certificates:${NC}"
CERTS=$(aws acm list-certificates --region "$SOURCE_REGION" \
    --query 'CertificateSummaryList[].[CertificateArn,DomainName,Status,Type]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$CERTS" && "$CERTS" != "None" ]]; then
    echo "$CERTS" | while IFS=$'\t' read -r carn domain status ctype; do
        echo "    - $domain | $status | $ctype"
        echo "      ARN: $carn"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}Secrets Manager Secrets:${NC}"
SECRETS=$(aws secretsmanager list-secrets --region "$SOURCE_REGION" \
    --query 'SecretList[].[Name,Description,LastChangedDate]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$SECRETS" && "$SECRETS" != "None" ]]; then
    echo "$SECRETS" | while IFS=$'\t' read -r sname sdesc sdate; do
        echo "    - $sname | ${sdesc:-No description} | Last changed: ${sdate:-N/A}"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}SSM Parameter Store:${NC}"
SSM_PARAMS=$(aws ssm describe-parameters --region "$SOURCE_REGION" \
    --query 'Parameters[].[Name,Type,Version]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$SSM_PARAMS" && "$SSM_PARAMS" != "None" ]]; then
    echo "$SSM_PARAMS" | while IFS=$'\t' read -r pname ptype pver; do
        echo "    - $pname | Type: $ptype | Version: $pver"
    done
    PARAM_COUNT=$(echo "$SSM_PARAMS" | wc -l | tr -d ' ')
    echo "    Total: $PARAM_COUNT parameter(s)"
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}WAF Web ACLs (Regional):${NC}"
WAF_ACLS=$(aws wafv2 list-web-acls --region "$SOURCE_REGION" --scope REGIONAL \
    --query 'WebACLs[].[Name,Id,ARN]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$WAF_ACLS" && "$WAF_ACLS" != "None" ]]; then
    echo "$WAF_ACLS" | while IFS=$'\t' read -r wname wid warn; do
        echo "    - $wname | ID: $wid"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}IAM Instance Profiles:${NC}"
INSTANCE_PROFILES=$(aws iam list-instance-profiles \
    --query 'InstanceProfiles[].[InstanceProfileName,Roles[0].RoleName]' \
    --output text 2>/dev/null || echo "")
if [[ -n "$INSTANCE_PROFILES" && "$INSTANCE_PROFILES" != "None" ]]; then
    echo "$INSTANCE_PROFILES" | while IFS=$'\t' read -r ipname rname; do
        echo "    - Profile: $ipname | Role: ${rname:-N/A}"
    done
else
    echo "    (none)"
fi

echo -e "\n  ${BOLD}KMS Keys (customer-managed):${NC}"
KMS_KEYS=$(aws kms list-keys --region "$SOURCE_REGION" \
    --query 'Keys[].KeyId' --output text 2>/dev/null || echo "")
KMS_COUNT=0
if [[ -n "$KMS_KEYS" && "$KMS_KEYS" != "None" ]]; then
    for kid in $KMS_KEYS; do
        key_info=$(aws kms describe-key --region "$SOURCE_REGION" --key-id "$kid" \
            --query 'KeyMetadata.[KeyId,KeyState,KeyManager,Description]' \
            --output text 2>/dev/null || echo "")
        IFS=$'\t' read -r keyid state manager desc <<< "$key_info"
        if [[ "$manager" == "CUSTOMER" ]]; then
            echo "    - $keyid | State: $state | $desc"
            KMS_COUNT=$((KMS_COUNT + 1))
        fi
    done
    echo "    Total: $KMS_COUNT customer-managed key(s)"
else
    echo "    (none)"
fi

# ════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════
echo ""
divider
echo -e "${BOLD}  INVENTORY COMPLETE${NC}"
echo -e "${BOLD}  Account: ${ACCOUNT_ID} | Region: ${SOURCE_REGION}${NC}"
divider
echo ""
log_info "Report saved to: ${REPORT_FILE}"
log_info "Run with different accounts: AWS_PROFILE=<profile> ./dr-inventory.sh"
echo ""
