#!/bin/bash
set -euo pipefail

# ============================================================
# AWS DR Serverless Migration Script
# ============================================================
# Audits and migrates DynamoDB, Lambda, and API Gateway
# resources from source region to DR region.
#
# Commands:
#   audit       - Read-only scan of all serverless resources
#   dynamodb    - Enable DynamoDB Global Tables for DR region
#   lambda      - Export and deploy Lambda functions to DR region
#   apigateway  - Export REST APIs and recreate HTTP APIs in DR region
#   cleanup     - Find and delete orphaned API Gateway integrations
#
# Usage:
#   ./dr-serverless-migrate.sh audit
#   ./dr-serverless-migrate.sh dynamodb [--dry-run]
#   ./dr-serverless-migrate.sh lambda [--dry-run] [--skip-deprecated]
#   ./dr-serverless-migrate.sh apigateway [--dry-run]
#   ./dr-serverless-migrate.sh cleanup [--dry-run]
#
# Environment:
#   SOURCE_REGION  - Source region (default: me-south-1)
#   DEST_REGION    - DR region (default: eu-west-1)
# ============================================================

SOURCE_REGION="${SOURCE_REGION:-me-south-1}"
DEST_REGION="${DEST_REGION:-eu-west-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${CYAN}==>${NC} ${BOLD}$*${NC}"; }
divider()   { echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"; }

# Safe increment
inc() { eval "$1=\$(( ${!1} + 1 ))"; }

# Deprecated runtimes list
is_deprecated_runtime() {
    local runtime="$1"
    case "$runtime" in
        nodejs14.x|nodejs16.x|python3.7|python3.8|dotnetcore3.1|ruby2.7|java8|go1.x)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

suggest_upgrade() {
    local runtime="$1"
    case "$runtime" in
        nodejs14.x|nodejs16.x)  echo "nodejs20.x or nodejs22.x" ;;
        python3.7|python3.8)    echo "python3.12 or python3.13" ;;
        dotnetcore3.1)          echo "dotnet8" ;;
        ruby2.7)                echo "ruby3.3" ;;
        java8)                  echo "java21" ;;
        go1.x)                  echo "provided.al2023 (custom runtime)" ;;
        *)                      echo "latest" ;;
    esac
}

# ── Pre-flight checks ──────────────────────────────────────
command -v aws >/dev/null 2>&1 || { log_error "AWS CLI not found."; exit 1; }
command -v jq >/dev/null 2>&1  || { log_error "jq not found."; exit 1; }
command -v curl >/dev/null 2>&1 || { log_error "curl not found."; exit 1; }

# ── Parse arguments ────────────────────────────────────────
COMMAND="${1:-}"
shift || true

DRY_RUN=false
SKIP_DEPRECATED=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)          DRY_RUN=true; shift ;;
        --skip-deprecated)  SKIP_DEPRECATED=true; shift ;;
        --region)           SOURCE_REGION="$2"; shift 2 ;;
        --dr-region)        DEST_REGION="$2"; shift 2 ;;
        *)                  log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$COMMAND" ]]; then
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  audit       Read-only scan of DynamoDB, Lambda, API Gateway"
    echo "  dynamodb    Enable DynamoDB Global Tables for DR region"
    echo "  lambda      Deploy Lambda functions to DR region"
    echo "  apigateway  Export/recreate API Gateway in DR region"
    echo ""
    echo "Options:"
    echo "  --dry-run          Preview changes without executing"
    echo "  --skip-deprecated  Skip Lambda functions with deprecated runtimes"
    echo "  --region           Source region (default: me-south-1)"
    echo "  --dr-region        DR region (default: eu-west-1)"
    exit 0
fi

# ── Identity ───────────────────────────────────────────────
echo ""
divider
echo -e "${BOLD}  AWS DR SERVERLESS MIGRATION${NC}"
$DRY_RUN && echo -e "${YELLOW}  [DRY RUN MODE — no changes will be made]${NC}"
divider

log_step "Detecting AWS identity..."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "")
[[ -z "$ACCOUNT_ALIAS" || "$ACCOUNT_ALIAS" == "None" ]] && ACCOUNT_ALIAS=""
ACCOUNT_LABEL="${ACCOUNT_ALIAS:-$ACCOUNT_ID}"

log_info "Account : $ACCOUNT_ID ($ACCOUNT_LABEL)"
log_info "Identity: $CALLER_ARN"
log_info "Source  : $SOURCE_REGION"
log_info "DR      : $DEST_REGION"
log_info "Command : $COMMAND"
$DRY_RUN && log_info "Mode    : DRY RUN"
divider

# ════════════════════════════════════════════════════════════
# AUDIT COMMAND
# ════════════════════════════════════════════════════════════
cmd_audit() {
    local ddb_count=0
    local lambda_count=0
    local lambda_deprecated=0
    local apigw_rest_count=0
    local apigw_http_count=0

    # ── DynamoDB ──────────────────────────────────────────
    log_step "1. DYNAMODB TABLES ($SOURCE_REGION)"

    DDB_TABLES=$(aws dynamodb list-tables --region "$SOURCE_REGION" \
        --query 'TableNames[]' --output text 2>/dev/null || echo "")

    if [[ -n "$DDB_TABLES" && "$DDB_TABLES" != "None" ]]; then
        for table in $DDB_TABLES; do
            inc ddb_count
            table_info=$(aws dynamodb describe-table --region "$SOURCE_REGION" \
                --table-name "$table" 2>/dev/null || echo "")

            if [[ -n "$table_info" ]]; then
                status=$(echo "$table_info" | jq -r '.Table.TableStatus')
                items=$(echo "$table_info" | jq -r '.Table.ItemCount')
                size=$(echo "$table_info" | jq -r '.Table.TableSizeBytes')
                billing=$(echo "$table_info" | jq -r '.Table.BillingModeSummary.BillingMode // "PROVISIONED"')
                global_table=$(echo "$table_info" | jq -r '.Table.Replicas // [] | length')
                has_dr_replica=$(echo "$table_info" | jq -r ".Table.Replicas[]? | select(.RegionName==\"$DEST_REGION\") | .ReplicaStatus" 2>/dev/null || echo "")
                size_hr=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size} bytes")

                local gt_status=""
                if [[ -n "$has_dr_replica" ]]; then
                    gt_status=" | ${GREEN}Global Table: $has_dr_replica${NC}"
                fi

                echo -e "    - $table | $status | Items: $items | Size: $size_hr | $billing${gt_status}"

                # Warnings
                if [[ "$billing" == "PROVISIONED" ]]; then
                    log_warn "  '$table' uses PROVISIONED billing — must specify capacity or switch to PAY_PER_REQUEST before enabling Global Tables"
                fi
                if [[ -n "$has_dr_replica" ]]; then
                    echo -e "      ${GREEN}✓${NC} Already replicated to $DEST_REGION ($has_dr_replica)"
                fi
            fi
        done
        echo "    Total: $ddb_count table(s)"
    else
        echo "    (none)"
    fi

    # ── Lambda ────────────────────────────────────────────
    log_step "2. LAMBDA FUNCTIONS ($SOURCE_REGION)"

    LAMBDA_JSON=$(aws lambda list-functions --region "$SOURCE_REGION" \
        --query 'Functions[].[FunctionName,Runtime,MemorySize,Timeout,Handler,CodeSize,Architectures[0],PackageType]' \
        --output json 2>/dev/null || echo "[]")

    LAMBDA_COUNT=$(echo "$LAMBDA_JSON" | jq 'length')

    if [[ "$LAMBDA_COUNT" -gt 0 ]]; then
        while IFS= read -r func; do
            fname=$(echo "$func" | jq -r '.[0]')
            runtime=$(echo "$func" | jq -r '.[1] // "N/A"')
            mem=$(echo "$func" | jq -r '.[2]')
            timeout=$(echo "$func" | jq -r '.[3]')
            handler=$(echo "$func" | jq -r '.[4] // "N/A"')
            codesize=$(echo "$func" | jq -r '.[5]')
            arch=$(echo "$func" | jq -r '.[6] // "x86_64"')
            pkg_type=$(echo "$func" | jq -r '.[7] // "Zip"')

            size_hr=$(numfmt --to=iec "$codesize" 2>/dev/null || echo "${codesize} bytes")

            local deprecated_marker=""
            if is_deprecated_runtime "$runtime"; then
                deprecated_marker=" ${RED}[DEPRECATED → $(suggest_upgrade "$runtime")]${NC}"
                lambda_deprecated=$((lambda_deprecated + 1))
            fi

            echo -e "    - $fname"
            echo -e "      Runtime: ${runtime}${deprecated_marker} | Memory: ${mem}MB | Timeout: ${timeout}s | Code: $size_hr | Arch: $arch | Pkg: $pkg_type"

            # Check if function exists in DR region
            if aws lambda get-function --function-name "$fname" --region "$DEST_REGION" &>/dev/null; then
                echo -e "      ${GREEN}✓${NC} Already exists in $DEST_REGION"
            fi

            lambda_count=$((lambda_count + 1))
        done < <(echo "$LAMBDA_JSON" | jq -c '.[]')
        echo "    Total: $LAMBDA_COUNT function(s)"
    else
        echo "    (none)"
    fi

    # Check for layers
    echo -e "\n  ${BOLD}Lambda Layers:${NC}"
    LAYERS=$(aws lambda list-layers --region "$SOURCE_REGION" \
        --query 'Layers[].[LayerName,LatestMatchingVersion.Version,LatestMatchingVersion.CompatibleRuntimes[0]]' \
        --output text 2>/dev/null || echo "")
    if [[ -n "$LAYERS" && "$LAYERS" != "None" ]]; then
        echo "$LAYERS" | while IFS=$'\t' read -r lname lver lruntime; do
            echo "    - $lname | Version: $lver | Runtime: ${lruntime:-N/A}"
            if aws lambda get-layer-version --layer-name "$lname" --version-number "$lver" \
                --region "$DEST_REGION" &>/dev/null 2>&1; then
                echo -e "      ${GREEN}✓${NC} Already exists in $DEST_REGION"
            fi
        done
    else
        echo "    (none)"
    fi

    # ── API Gateway ───────────────────────────────────────
    log_step "3. API GATEWAY ($SOURCE_REGION)"

    echo -e "\n  ${BOLD}REST APIs:${NC}"
    REST_APIS=$(aws apigateway get-rest-apis --region "$SOURCE_REGION" \
        --query 'items[].[id,name,description,endpointConfiguration.types[0]]' \
        --output text 2>/dev/null || echo "")
    if [[ -n "$REST_APIS" && "$REST_APIS" != "None" ]]; then
        while IFS=$'\t' read -r aid aname adesc etype; do
            echo "    - $aname ($aid) | Endpoint: ${etype:-N/A}"
            echo "      ${adesc:-No description}"

            # Check stages
            stages=$(aws apigateway get-stages --rest-api-id "$aid" --region "$SOURCE_REGION" \
                --query 'item[].stageName' --output text 2>/dev/null || echo "")
            [[ -n "$stages" ]] && echo "      Stages: $stages"

            inc apigw_rest_count
        done <<< "$REST_APIS"
        echo "    Total: $apigw_rest_count REST API(s) — exportable via OpenAPI"
    else
        echo "    (none)"
    fi

    echo -e "\n  ${BOLD}HTTP APIs (API Gateway v2):${NC}"
    HTTP_APIS=$(aws apigatewayv2 get-apis --region "$SOURCE_REGION" \
        --query 'Items[].[ApiId,Name,ProtocolType,ApiEndpoint]' \
        --output text 2>/dev/null || echo "")
    if [[ -n "$HTTP_APIS" && "$HTTP_APIS" != "None" ]]; then
        while IFS=$'\t' read -r aid aname proto endpoint; do
            echo "    - $aname ($aid) | $proto | $endpoint"

            # Check integrations (show unique only)
            integrations_json=$(aws apigatewayv2 get-integrations --api-id "$aid" --region "$SOURCE_REGION" 2>/dev/null || echo '{"Items":[]}')
            int_total=$(echo "$integrations_json" | jq '.Items | length')
            unique_lines=$(echo "$integrations_json" | jq -r '[.Items[]? | "\(.IntegrationType) → \(.IntegrationUri // "N/A")"] | unique | .[]' 2>/dev/null || echo "")
            unique_count=$(echo "$unique_lines" | grep -c . || true)
            # Count routes and detect orphaned integrations
            route_targets=$(aws apigatewayv2 get-routes --api-id "$aid" --region "$SOURCE_REGION" \
                --query 'Items[].Target' --output text 2>/dev/null || echo "")
            route_count=$(aws apigatewayv2 get-routes --api-id "$aid" --region "$SOURCE_REGION" \
                --query 'Items | length' --output text 2>/dev/null || echo "0")

            # Build set of integration IDs referenced by routes
            used_int_ids=""
            for target in $route_targets; do
                if [[ "$target" == integrations/* ]]; then
                    used_int_ids="$used_int_ids ${target#integrations/}"
                fi
            done
            used_count=$(echo "$used_int_ids" | tr ' ' '\n' | sort -u | grep -c . || true)
            orphaned=$((int_total - used_count))

            if [[ $int_total -gt 0 ]]; then
                echo "      Routes: $route_count | Integrations: $int_total (used: $used_count, orphaned: $orphaned)"
                while IFS= read -r uline; do
                    [[ -z "$uline" ]] && continue
                    echo "        - $uline"
                done <<< "$unique_lines"
                if [[ $orphaned -gt 0 ]]; then
                    echo -e "      ${YELLOW}⚠ $orphaned orphaned integration(s) — run: $0 cleanup${NC}"
                fi
            fi

            inc apigw_http_count
        done <<< "$HTTP_APIS"
        echo "    Total: $apigw_http_count HTTP API(s) — must recreate manually (no export/import)"
    else
        echo "    (none)"
    fi

    echo -e "\n  ${BOLD}Custom Domain Names:${NC}"
    DOMAINS=$(aws apigateway get-domain-names --region "$SOURCE_REGION" \
        --query 'items[].[domainName,certificateArn,endpointConfiguration.types[0]]' \
        --output text 2>/dev/null || echo "")
    if [[ -n "$DOMAINS" && "$DOMAINS" != "None" ]]; then
        while IFS=$'\t' read -r dname cert etype; do
            echo "    - $dname | $etype"
        done <<< "$DOMAINS"
    else
        echo "    (none)"
    fi

    # ── Summary ───────────────────────────────────────────
    echo ""
    divider
    echo -e "${BOLD}  SERVERLESS AUDIT SUMMARY${NC}"
    echo -e "${BOLD}  Account: ${ACCOUNT_ID} (${ACCOUNT_LABEL})${NC}"
    divider
    echo ""
    echo "    DynamoDB tables      : $ddb_count"
    echo "    Lambda functions     : $LAMBDA_COUNT"
    if [[ $lambda_deprecated -gt 0 ]]; then
        echo -e "      ${RED}Deprecated runtimes: $lambda_deprecated (upgrade before migrating)${NC}"
    fi
    echo "    REST APIs (export)   : $apigw_rest_count"
    echo "    HTTP APIs (recreate) : $apigw_http_count"
    echo ""

    if [[ $ddb_count -gt 0 || "$LAMBDA_COUNT" -gt 0 || $apigw_rest_count -gt 0 || $apigw_http_count -gt 0 ]]; then
        echo -e "  ${BOLD}Next Steps:${NC}"
        [[ $ddb_count -gt 0 ]] && echo "    1. Enable Global Tables:  $0 dynamodb [--dry-run]"
        [[ "$LAMBDA_COUNT" -gt 0 ]] && echo "    2. Migrate Lambda:        $0 lambda [--dry-run] [--skip-deprecated]"
        [[ $apigw_rest_count -gt 0 || $apigw_http_count -gt 0 ]] && echo "    3. Migrate API Gateway:   $0 apigateway [--dry-run]"
    else
        echo "    No serverless resources to migrate."
    fi

    divider
}

# ════════════════════════════════════════════════════════════
# DYNAMODB COMMAND
# ════════════════════════════════════════════════════════════
cmd_dynamodb() {
    log_step "DynamoDB Global Tables Migration"

    DDB_TABLES=$(aws dynamodb list-tables --region "$SOURCE_REGION" \
        --query 'TableNames[]' --output text 2>/dev/null || echo "")

    if [[ -z "$DDB_TABLES" || "$DDB_TABLES" == "None" ]]; then
        log_info "No DynamoDB tables found in $SOURCE_REGION."
        return
    fi

    local total=0
    local migrated=0
    local skipped=0
    local failed=0

    for table in $DDB_TABLES; do
        inc total
        echo ""
        log_step "Table: $table"

        # Get table details
        table_info=$(aws dynamodb describe-table --region "$SOURCE_REGION" \
            --table-name "$table" 2>/dev/null || echo "")

        if [[ -z "$table_info" ]]; then
            log_error "Cannot describe table '$table'"
            inc failed
            continue
        fi

        status=$(echo "$table_info" | jq -r '.Table.TableStatus')
        items=$(echo "$table_info" | jq -r '.Table.ItemCount')
        size=$(echo "$table_info" | jq -r '.Table.TableSizeBytes')
        billing=$(echo "$table_info" | jq -r '.Table.BillingModeSummary.BillingMode // "PROVISIONED"')
        has_dr=$(echo "$table_info" | jq -r ".Table.Replicas[]? | select(.RegionName==\"$DEST_REGION\") | .ReplicaStatus" 2>/dev/null || echo "")
        has_streams=$(echo "$table_info" | jq -r '.Table.StreamSpecification.StreamEnabled // false')
        size_hr=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size} bytes")

        echo "    Status: $status | Items: $items | Size: $size_hr | Billing: $billing | Streams: $has_streams"

        # Already replicated?
        if [[ -n "$has_dr" ]]; then
            log_info "Already has replica in $DEST_REGION (status: $has_dr) — skipping"
            inc skipped
            continue
        fi

        # Table must be ACTIVE
        if [[ "$status" != "ACTIVE" ]]; then
            log_warn "Table status is '$status' — must be ACTIVE. Skipping."
            inc skipped
            continue
        fi

        # PROVISIONED billing warning
        if [[ "$billing" == "PROVISIONED" ]]; then
            log_warn "Table uses PROVISIONED billing."
            read -rp "    Switch to PAY_PER_REQUEST before enabling Global Table? (y/n/skip): " billing_choice
            case "$billing_choice" in
                y|Y)
                    if $DRY_RUN; then
                        log_info "[DRY RUN] Would switch '$table' to PAY_PER_REQUEST"
                    else
                        log_info "Switching '$table' to PAY_PER_REQUEST..."
                        aws dynamodb update-table --table-name "$table" --region "$SOURCE_REGION" \
                            --billing-mode PAY_PER_REQUEST >/dev/null
                        log_info "Waiting for table to become ACTIVE..."
                        aws dynamodb wait table-exists --table-name "$table" --region "$SOURCE_REGION"
                        log_info "Done."
                    fi
                    ;;
                s|S|skip)
                    log_warn "Skipping '$table'."
                    inc skipped
                    continue
                    ;;
                *)
                    log_info "Proceeding with PROVISIONED billing — replica will inherit same capacity."
                    ;;
            esac
        fi

        # Streams must be enabled for Global Tables
        if [[ "$has_streams" != "true" ]]; then
            log_info "Enabling DynamoDB Streams (required for Global Tables)..."
            if ! $DRY_RUN; then
                aws dynamodb update-table --table-name "$table" --region "$SOURCE_REGION" \
                    --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES >/dev/null
                log_info "Waiting for table to become ACTIVE..."
                aws dynamodb wait table-exists --table-name "$table" --region "$SOURCE_REGION"
            else
                log_info "[DRY RUN] Would enable streams on '$table'"
            fi
        fi

        # Confirm
        read -rp "    Enable Global Table for '$table' in $DEST_REGION? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_warn "Skipping '$table'."
            inc skipped
            continue
        fi

        if $DRY_RUN; then
            log_info "[DRY RUN] Would create Global Table replica for '$table' in $DEST_REGION"
            inc migrated
            continue
        fi

        # Create replica
        log_info "Creating Global Table replica in $DEST_REGION..."
        set +e
        create_output=$(aws dynamodb update-table --table-name "$table" --region "$SOURCE_REGION" \
            --replica-updates "[{\"Create\":{\"RegionName\":\"$DEST_REGION\"}}]" 2>&1)
        create_rc=$?
        set -e

        if [[ $create_rc -eq 0 ]]; then
            log_info "Global Table replica creation initiated for '$table'"
            log_info "Waiting for replica to become ACTIVE (this may take a few minutes)..."

            # Poll until replica is active (wait doesn't support replicas directly)
            local attempts=0
            while [[ $attempts -lt 60 ]]; do
                replica_status=$(aws dynamodb describe-table --table-name "$table" --region "$SOURCE_REGION" \
                    --query "Table.Replicas[?RegionName=='$DEST_REGION'].ReplicaStatus" \
                    --output text 2>/dev/null || echo "")
                if [[ "$replica_status" == "ACTIVE" ]]; then
                    log_info "Replica for '$table' is ACTIVE in $DEST_REGION"
                    break
                fi
                echo -n "."
                sleep 5
                attempts=$((attempts + 1))
            done
            echo ""

            if [[ "$replica_status" != "ACTIVE" ]]; then
                log_warn "Replica not yet ACTIVE (status: $replica_status). It may still be provisioning."
            fi
            inc migrated
        else
            log_error "Failed to create replica for '$table':"
            echo "    $create_output"
            inc failed
        fi
    done

    # Summary
    echo ""
    divider
    echo -e "${BOLD}  DynamoDB Migration Summary${NC}"
    divider
    echo "    Total tables : $total"
    echo "    Migrated     : $migrated"
    echo "    Skipped      : $skipped"
    echo "    Failed       : $failed"
    divider
}

# ════════════════════════════════════════════════════════════
# LAMBDA COMMAND
# ════════════════════════════════════════════════════════════
cmd_lambda() {
    log_step "Lambda Function Migration"

    LAMBDA_JSON=$(aws lambda list-functions --region "$SOURCE_REGION" \
        --query 'Functions[]' --output json 2>/dev/null || echo "[]")

    LAMBDA_COUNT=$(echo "$LAMBDA_JSON" | jq 'length')

    if [[ "$LAMBDA_COUNT" -eq 0 ]]; then
        log_info "No Lambda functions found in $SOURCE_REGION."
        return
    fi

    log_info "Found $LAMBDA_COUNT function(s) in $SOURCE_REGION"

    # Migrate layers first
    log_step "Lambda Layers"
    LAYERS_JSON=$(aws lambda list-layers --region "$SOURCE_REGION" \
        --query 'Layers[]' --output json 2>/dev/null || echo "[]")
    LAYER_COUNT=$(echo "$LAYERS_JSON" | jq 'length')

    if [[ "$LAYER_COUNT" -gt 0 ]]; then
        log_info "Found $LAYER_COUNT layer(s)"
        while IFS= read -r layer; do
            layer_name=$(echo "$layer" | jq -r '.LayerName')
            layer_ver=$(echo "$layer" | jq -r '.LatestMatchingVersion.Version')

            # Check if already exists in DR
            if aws lambda get-layer-version --layer-name "$layer_name" \
                --version-number "$layer_ver" --region "$DEST_REGION" &>/dev/null 2>&1; then
                log_info "Layer '$layer_name' v$layer_ver already exists in $DEST_REGION — skipping"
                continue
            fi

            log_info "Migrating layer: $layer_name v$layer_ver"

            if $DRY_RUN; then
                log_info "[DRY RUN] Would migrate layer '$layer_name'"
                continue
            fi

            # Get layer version details
            layer_detail=$(aws lambda get-layer-version --layer-name "$layer_name" \
                --version-number "$layer_ver" --region "$SOURCE_REGION" 2>/dev/null || echo "")
            if [[ -z "$layer_detail" ]]; then
                log_warn "Cannot get layer details for '$layer_name' — skipping"
                continue
            fi

            layer_url=$(echo "$layer_detail" | jq -r '.Content.Location')
            layer_runtimes=$(echo "$layer_detail" | jq -r '.CompatibleRuntimes // [] | join(",")')
            layer_desc=$(echo "$layer_detail" | jq -r '.Description // ""')

            curl -s -o "/tmp/layer-${layer_name}.zip" "$layer_url"

            local layer_cmd=(
                aws lambda publish-layer-version
                --layer-name "$layer_name"
                --zip-file "fileb:///tmp/layer-${layer_name}.zip"
                --region "$DEST_REGION"
            )
            [[ -n "$layer_runtimes" ]] && layer_cmd+=(--compatible-runtimes ${layer_runtimes//,/ })
            [[ -n "$layer_desc" ]] && layer_cmd+=(--description "$layer_desc")

            set +e
            "${layer_cmd[@]}" >/dev/null 2>&1
            local layer_rc=$?
            set -e

            rm -f "/tmp/layer-${layer_name}.zip"

            if [[ $layer_rc -eq 0 ]]; then
                log_info "Layer '$layer_name' migrated to $DEST_REGION"
            else
                log_warn "Failed to migrate layer '$layer_name'"
            fi
        done < <(echo "$LAYERS_JSON" | jq -c '.[]')
    else
        log_info "No layers to migrate"
    fi

    # Migrate functions
    log_step "Lambda Functions"

    local total=0
    local migrated=0
    local skipped=0
    local failed=0

    while IFS= read -r func; do
        fname=$(echo "$func" | jq -r '.FunctionName')
        runtime=$(echo "$func" | jq -r '.Runtime // "N/A"')
        mem=$(echo "$func" | jq -r '.MemorySize')
        timeout=$(echo "$func" | jq -r '.Timeout')
        handler=$(echo "$func" | jq -r '.Handler // "N/A"')
        role=$(echo "$func" | jq -r '.Role')
        codesize=$(echo "$func" | jq -r '.CodeSize')
        arch=$(echo "$func" | jq -r '.Architectures[0] // "x86_64"')
        pkg_type=$(echo "$func" | jq -r '.PackageType // "Zip"')

        total=$((total + 1))
        size_hr=$(numfmt --to=iec "$codesize" 2>/dev/null || echo "${codesize} bytes")

        echo ""
        log_step "Function: $fname ($runtime, $size_hr)"

        # Check deprecated
        if is_deprecated_runtime "$runtime"; then
            log_warn "Deprecated runtime: $runtime → upgrade to $(suggest_upgrade "$runtime")"
            if $SKIP_DEPRECATED; then
                log_warn "Skipping (--skip-deprecated flag set)"
                skipped=$((skipped + 1))
                continue
            fi
            read -rp "    Migrate anyway with deprecated runtime? (y/n): " dep_confirm < /dev/tty
            if [[ "$dep_confirm" != "y" && "$dep_confirm" != "Y" ]]; then
                log_warn "Skipping '$fname'. Upgrade runtime first, then re-run."
                skipped=$((skipped + 1))
                continue
            fi
        fi

        # Container image functions
        if [[ "$pkg_type" == "Image" ]]; then
            log_warn "Function uses container image — must push image to ECR in $DEST_REGION first."
            log_warn "Skipping '$fname'. Set up ECR replication, then create function manually."
            skipped=$((skipped + 1))
            continue
        fi

        # Check if already exists in DR
        if aws lambda get-function --function-name "$fname" --region "$DEST_REGION" &>/dev/null; then
            log_info "Function '$fname' already exists in $DEST_REGION — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        # Confirmation
        read -rp "    Deploy '$fname' to $DEST_REGION? (y/n): " confirm < /dev/tty
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_warn "Skipping '$fname'."
            skipped=$((skipped + 1))
            continue
        fi

        if $DRY_RUN; then
            log_info "[DRY RUN] Would deploy '$fname' to $DEST_REGION"
            migrated=$((migrated + 1))
            continue
        fi

        # Download function code
        log_info "Downloading function code..."
        func_detail=$(aws lambda get-function --function-name "$fname" --region "$SOURCE_REGION" 2>/dev/null || echo "")
        code_url=$(echo "$func_detail" | jq -r '.Code.Location')

        if [[ -z "$code_url" || "$code_url" == "null" ]]; then
            log_error "Cannot get code download URL for '$fname'"
            failed=$((failed + 1))
            continue
        fi

        curl -s -o "/tmp/lambda-${fname}.zip" "$code_url"

        # Extract environment variables
        env_vars=$(echo "$func" | jq -c '.Environment // empty')

        # Extract VPC config
        vpc_config=$(echo "$func" | jq -c '.VpcConfig // empty | if .SubnetIds and (.SubnetIds | length > 0) then {SubnetIds: .SubnetIds, SecurityGroupIds: .SecurityGroupIds} else empty end' 2>/dev/null || echo "")

        # Extract layers (remap ARNs to DR region)
        layers=$(echo "$func" | jq -r '.Layers[]?.Arn // empty' 2>/dev/null | \
            sed "s/$SOURCE_REGION/$DEST_REGION/g" || echo "")

        # Build create command
        local create_cmd=(
            aws lambda create-function
            --function-name "$fname"
            --runtime "$runtime"
            --handler "$handler"
            --memory-size "$mem"
            --timeout "$timeout"
            --role "$role"
            --zip-file "fileb:///tmp/lambda-${fname}.zip"
            --architectures "$arch"
            --region "$DEST_REGION"
        )

        [[ -n "$env_vars" ]] && create_cmd+=(--environment "$env_vars")

        if [[ -n "$vpc_config" ]]; then
            log_warn "Function has VPC config — ensure subnets/SGs exist in $DEST_REGION"
            log_warn "VPC config: $vpc_config"
            log_warn "Skipping VPC config in DR deployment (can be added after DR VPC is set up)"
        fi

        if [[ -n "$layers" ]]; then
            local layer_arns=()
            for larn in $layers; do
                layer_arns+=("$larn")
            done
            if [[ ${#layer_arns[@]} -gt 0 ]]; then
                create_cmd+=(--layers "${layer_arns[@]}")
            fi
        fi

        log_info "Creating function in $DEST_REGION..."
        set +e
        create_output=$("${create_cmd[@]}" 2>&1)
        create_rc=$?
        set -e

        rm -f "/tmp/lambda-${fname}.zip"

        if [[ $create_rc -eq 0 ]]; then
            log_info "Function '$fname' deployed to $DEST_REGION"
            migrated=$((migrated + 1))
        else
            log_error "Failed to deploy '$fname':"
            echo "    $create_output"
            failed=$((failed + 1))
        fi
    done < <(echo "$LAMBDA_JSON" | jq -c '.[]')

    # Summary
    echo ""
    divider
    echo -e "${BOLD}  Lambda Migration Summary${NC}"
    divider
    echo "    Total functions : $total"
    echo "    Migrated        : $migrated"
    echo "    Skipped         : $skipped"
    echo "    Failed          : $failed"
    divider
}

# ════════════════════════════════════════════════════════════
# API GATEWAY COMMAND
# ════════════════════════════════════════════════════════════
cmd_apigateway() {
    log_step "API Gateway Migration"

    local rest_total=0
    local rest_migrated=0
    local http_total=0
    local http_migrated=0
    local skipped=0
    local failed=0

    # ── REST APIs (exportable) ────────────────────────────
    log_step "REST APIs (export/import)"

    REST_APIS=$(aws apigateway get-rest-apis --region "$SOURCE_REGION" \
        --query 'items[].[id,name]' --output text 2>/dev/null || echo "")

    if [[ -n "$REST_APIS" && "$REST_APIS" != "None" ]]; then
        while IFS=$'\t' read -r api_id api_name; do
            inc rest_total
            echo ""
            log_step "REST API: $api_name ($api_id)"

            # Get stages
            stages=$(aws apigateway get-stages --rest-api-id "$api_id" --region "$SOURCE_REGION" \
                --query 'item[].stageName' --output text 2>/dev/null || echo "prod")

            echo "    Stages: ${stages:-none}"

            # Check if already exists in DR (by name)
            existing=$(aws apigateway get-rest-apis --region "$DEST_REGION" \
                --query "items[?name=='$api_name'].id" --output text 2>/dev/null || echo "")
            if [[ -n "$existing" && "$existing" != "None" ]]; then
                log_info "REST API '$api_name' already exists in $DEST_REGION ($existing) — skipping"
                inc skipped
                continue
            fi

            read -rp "    Export and import '$api_name' to $DEST_REGION? (y/n): " confirm < /dev/tty
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                log_warn "Skipping '$api_name'."
                inc skipped
                continue
            fi

            if $DRY_RUN; then
                log_info "[DRY RUN] Would export '$api_name' and import to $DEST_REGION"
                inc rest_migrated
                continue
            fi

            # Determine stage to export (prefer prod, then first available)
            local export_stage=""
            for s in $stages; do
                if [[ "$s" == "prod" || "$s" == "production" ]]; then
                    export_stage="$s"
                    break
                fi
            done
            [[ -z "$export_stage" ]] && export_stage=$(echo "$stages" | awk '{print $1}')

            if [[ -z "$export_stage" || "$export_stage" == "None" ]]; then
                log_warn "No stages found for '$api_name' — cannot export. Skipping."
                inc skipped
                continue
            fi

            log_info "Exporting '$api_name' from stage '$export_stage'..."

            set +e
            aws apigateway get-export \
                --rest-api-id "$api_id" \
                --stage-name "$export_stage" \
                --export-type oas30 \
                --accepts application/json \
                "/tmp/api-${api_id}.json" \
                --region "$SOURCE_REGION" 2>/dev/null
            export_rc=$?
            set -e

            if [[ $export_rc -ne 0 ]]; then
                log_error "Failed to export '$api_name'"
                inc failed
                continue
            fi

            log_info "Importing '$api_name' into $DEST_REGION..."

            set +e
            import_output=$(aws apigateway import-rest-api \
                --body "file:///tmp/api-${api_id}.json" \
                --region "$DEST_REGION" 2>&1)
            import_rc=$?
            set -e

            rm -f "/tmp/api-${api_id}.json"

            if [[ $import_rc -eq 0 ]]; then
                new_api_id=$(echo "$import_output" | jq -r '.id // "N/A"')
                log_info "REST API '$api_name' imported to $DEST_REGION (new ID: $new_api_id)"

                # Create deployment
                log_info "Creating deployment for stage '$export_stage'..."
                aws apigateway create-deployment --rest-api-id "$new_api_id" \
                    --stage-name "$export_stage" --region "$DEST_REGION" >/dev/null 2>&1 || \
                    log_warn "Could not create deployment — create stage manually"

                inc rest_migrated
            else
                log_error "Failed to import '$api_name':"
                echo "    $import_output"
                inc failed
            fi
        done <<< "$REST_APIS"
    else
        log_info "No REST APIs found."
    fi

    # ── HTTP APIs (must recreate) ─────────────────────────
    log_step "HTTP APIs (recreate)"

    HTTP_APIS_JSON=$(aws apigatewayv2 get-apis --region "$SOURCE_REGION" \
        --query 'Items[]' --output json 2>/dev/null || echo "[]")

    HTTP_COUNT=$(echo "$HTTP_APIS_JSON" | jq 'length')

    if [[ "$HTTP_COUNT" -gt 0 ]]; then
        while IFS= read -r api; do
            api_id=$(echo "$api" | jq -r '.ApiId')
            api_name=$(echo "$api" | jq -r '.Name')
            proto=$(echo "$api" | jq -r '.ProtocolType')

            http_total=$((http_total + 1))
            echo ""
            log_step "HTTP API: $api_name ($api_id, $proto)"

            # Check if already exists in DR
            existing=$(aws apigatewayv2 get-apis --region "$DEST_REGION" \
                --query "Items[?Name=='$api_name'].ApiId" --output text 2>/dev/null || echo "")
            if [[ -n "$existing" && "$existing" != "None" ]]; then
                log_info "HTTP API '$api_name' already exists in $DEST_REGION ($existing) — skipping"
                skipped=$((skipped + 1))
                continue
            fi

            # Get integrations (for display — deduplicate by URI)
            integrations=$(aws apigatewayv2 get-integrations --api-id "$api_id" --region "$SOURCE_REGION" 2>/dev/null || echo '{"Items":[]}')
            int_count=$(echo "$integrations" | jq '.Items | length')

            # Show unique integrations only (many APIs have duplicate integrations per route)
            unique_uris=$(echo "$integrations" | jq -r '[.Items[]? | "\(.IntegrationType) → \(.IntegrationUri // "N/A")"] | unique | .[]' 2>/dev/null || echo "")
            unique_int_count=$(echo "$unique_uris" | grep -c . || true)
            echo "    Integrations: $int_count ($unique_int_count unique)"
            while IFS= read -r uri_line; do
                [[ -z "$uri_line" ]] && continue
                echo "      - $uri_line"
            done <<< "$unique_uris"

            # Get routes with their target integration IDs
            routes_json=$(aws apigatewayv2 get-routes --api-id "$api_id" --region "$SOURCE_REGION" 2>/dev/null || echo '{"Items":[]}')
            route_count=$(echo "$routes_json" | jq '.Items | length')
            if [[ $route_count -gt 0 ]]; then
                echo "    Routes: $route_count"
                while IFS= read -r rline; do
                    [[ -z "$rline" ]] && continue
                    echo "      - $rline"
                done < <(echo "$routes_json" | jq -r '.Items[]? | .RouteKey')
            fi

            read -rp "    Recreate '$api_name' in $DEST_REGION? (y/n): " confirm < /dev/tty
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                log_warn "Skipping '$api_name'."
                skipped=$((skipped + 1))
                continue
            fi

            if $DRY_RUN; then
                log_info "[DRY RUN] Would recreate '$api_name' in $DEST_REGION ($route_count routes, $unique_int_count unique integrations)"
                http_migrated=$((http_migrated + 1))
                continue
            fi

            # Create the API
            log_info "Creating HTTP API '$api_name' in $DEST_REGION..."
            set +e
            new_api_output=$(aws apigatewayv2 create-api \
                --name "$api_name" \
                --protocol-type "$proto" \
                --region "$DEST_REGION" 2>&1)
            new_api_rc=$?
            set -e

            if [[ $new_api_rc -ne 0 ]]; then
                log_error "Failed to create HTTP API '$api_name':"
                echo "    $new_api_output"
                failed=$((failed + 1))
                continue
            fi

            new_api_id=$(echo "$new_api_output" | jq -r '.ApiId')
            log_info "Created HTTP API '$api_name' ($new_api_id)"

            # Route-based approach: for each route, find its integration, deduplicate
            # Map: "src_id=new_id" pairs stored in a string (Bash 3.2 compatible)
            int_id_map=""

            while IFS= read -r route_entry; do
                [[ -z "$route_entry" ]] && continue
                route_key=$(echo "$route_entry" | jq -r '.RouteKey')
                route_target=$(echo "$route_entry" | jq -r '.Target // empty')

                # Extract source integration ID from target (format: "integrations/XXXXX")
                src_int_id=""
                if [[ "$route_target" == integrations/* ]]; then
                    src_int_id="${route_target#integrations/}"
                fi

                # If route has no target integration, create route without target
                if [[ -z "$src_int_id" ]]; then
                    aws apigatewayv2 create-route --api-id "$new_api_id" \
                        --route-key "$route_key" \
                        --region "$DEST_REGION" >/dev/null 2>&1 && \
                        log_info "  Created route: $route_key (no integration)" || \
                        log_warn "  Failed to create route: $route_key"
                    continue
                fi

                # Check if we already created this integration in DR (string lookup)
                new_int_id=""
                if [[ -n "$int_id_map" ]]; then
                    mapped=$(echo "$int_id_map" | grep "^${src_int_id}=" 2>/dev/null || echo "")
                    if [[ -n "$mapped" ]]; then
                        new_int_id="${mapped#*=}"
                    fi
                fi

                if [[ -z "$new_int_id" ]]; then
                    # Look up the source integration details
                    src_intg=$(echo "$integrations" | jq -c ".Items[]? | select(.IntegrationId==\"$src_int_id\")" 2>/dev/null || echo "")

                    if [[ -z "$src_intg" ]]; then
                        log_warn "  Integration $src_int_id not found — creating route without target"
                        aws apigatewayv2 create-route --api-id "$new_api_id" \
                            --route-key "$route_key" \
                            --region "$DEST_REGION" >/dev/null 2>&1 || true
                        continue
                    fi

                    itype=$(echo "$src_intg" | jq -r '.IntegrationType')
                    imethod=$(echo "$src_intg" | jq -r '.IntegrationMethod // "POST"')
                    iuri=$(echo "$src_intg" | jq -r '.IntegrationUri // empty')
                    payload=$(echo "$src_intg" | jq -r '.PayloadFormatVersion // "2.0"')

                    if [[ -z "$iuri" ]]; then
                        log_warn "  Integration has no URI — skipping"
                        continue
                    fi

                    # Remap Lambda ARN to DR region
                    dr_uri=$(echo "$iuri" | sed "s/$SOURCE_REGION/$DEST_REGION/g")

                    local int_cmd=(
                        aws apigatewayv2 create-integration
                        --api-id "$new_api_id"
                        --integration-type "$itype"
                        --integration-method "$imethod"
                        --payload-format-version "$payload"
                        --region "$DEST_REGION"
                    )
                    [[ -n "$dr_uri" ]] && int_cmd+=(--integration-uri "$dr_uri")

                    set +e
                    int_output=$("${int_cmd[@]}" 2>&1)
                    int_rc=$?
                    set -e

                    if [[ $int_rc -eq 0 ]]; then
                        new_int_id=$(echo "$int_output" | jq -r '.IntegrationId')
                        int_id_map="${int_id_map}${src_int_id}=${new_int_id}"$'\n'
                        log_info "  Created integration: $itype → $dr_uri ($new_int_id)"
                    else
                        log_warn "  Failed to create integration: $int_output"
                        continue
                    fi
                fi

                # Create route pointing to the (new or existing) integration
                aws apigatewayv2 create-route --api-id "$new_api_id" \
                    --route-key "$route_key" \
                    --target "integrations/$new_int_id" \
                    --region "$DEST_REGION" >/dev/null 2>&1 && \
                    log_info "  Created route: $route_key → $new_int_id" || \
                    log_warn "  Failed to create route: $route_key"
            done < <(echo "$routes_json" | jq -c '.Items[]?')

            # Create default stage with auto-deploy
            aws apigatewayv2 create-stage --api-id "$new_api_id" \
                --stage-name '$default' --auto-deploy \
                --region "$DEST_REGION" >/dev/null 2>&1 && \
                log_info "Created \$default stage with auto-deploy" || \
                log_warn "Could not create default stage"

            http_migrated=$((http_migrated + 1))
        done < <(echo "$HTTP_APIS_JSON" | jq -c '.[]')
    else
        log_info "No HTTP APIs found."
    fi

    # ── Custom Domains ────────────────────────────────────
    log_step "Custom Domain Names"

    DOMAINS=$(aws apigateway get-domain-names --region "$SOURCE_REGION" \
        --query 'items[].[domainName,certificateArn,endpointConfiguration.types[0]]' \
        --output text 2>/dev/null || echo "")

    if [[ -n "$DOMAINS" && "$DOMAINS" != "None" ]]; then
        while IFS=$'\t' read -r dname cert etype; do
            echo "    - $dname | $etype"
            log_warn "Custom domain '$dname' requires ACM certificate in $DEST_REGION before it can be created."
            log_warn "Create the certificate first, then: aws apigateway create-domain-name --domain-name '$dname' --region $DEST_REGION"
        done <<< "$DOMAINS"
    else
        log_info "No custom domains."
    fi

    # Summary
    echo ""
    divider
    echo -e "${BOLD}  API Gateway Migration Summary${NC}"
    divider
    echo "    REST APIs : $rest_total total, $rest_migrated migrated"
    echo "    HTTP APIs : $http_total total, $http_migrated migrated"
    echo "    Skipped   : $skipped"
    echo "    Failed    : $failed"
    divider
}

# ════════════════════════════════════════════════════════════
# CLEANUP COMMAND
# ════════════════════════════════════════════════════════════
cmd_cleanup() {
    log_step "API Gateway Cleanup — Orphaned Integrations"

    local total_orphaned=0
    local total_deleted=0

    # Scan both source and DR regions
    for region in "$SOURCE_REGION" "$DEST_REGION"; do
        log_step "Scanning HTTP APIs in $region"

        HTTP_APIS=$(aws apigatewayv2 get-apis --region "$region" \
            --query 'Items[].[ApiId,Name]' --output text 2>/dev/null || echo "")

        if [[ -z "$HTTP_APIS" || "$HTTP_APIS" == "None" ]]; then
            log_info "No HTTP APIs in $region"
            continue
        fi

        while IFS=$'\t' read -r api_id api_name; do
            # Get all integration IDs
            all_int_ids=$(aws apigatewayv2 get-integrations --api-id "$api_id" --region "$region" \
                --query 'Items[].IntegrationId' --output text 2>/dev/null || echo "")

            if [[ -z "$all_int_ids" || "$all_int_ids" == "None" ]]; then
                continue
            fi

            int_count=0
            for _ in $all_int_ids; do int_count=$((int_count + 1)); done

            # Get integration IDs used by routes
            route_targets=$(aws apigatewayv2 get-routes --api-id "$api_id" --region "$region" \
                --query 'Items[].Target' --output text 2>/dev/null || echo "")

            used_ids=""
            for target in $route_targets; do
                if [[ "$target" == integrations/* ]]; then
                    used_ids="$used_ids ${target#integrations/}"
                fi
            done

            # Find orphaned integration IDs
            orphaned_ids=()
            for int_id in $all_int_ids; do
                is_used=false
                for uid in $used_ids; do
                    if [[ "$int_id" == "$uid" ]]; then
                        is_used=true
                        break
                    fi
                done
                if ! $is_used; then
                    orphaned_ids+=("$int_id")
                fi
            done

            orphaned_count=${#orphaned_ids[@]}
            if [[ $orphaned_count -eq 0 ]]; then
                continue
            fi

            total_orphaned=$((total_orphaned + orphaned_count))
            used_count=$((int_count - orphaned_count))

            echo ""
            log_warn "$api_name ($api_id) in $region"
            echo "    Integrations: $int_count total | Used by routes: $used_count | Orphaned: $orphaned_count"

            # Show what the orphaned integrations point to
            sample_uri=$(aws apigatewayv2 get-integration --api-id "$api_id" \
                --integration-id "${orphaned_ids[0]}" --region "$region" \
                --query '[IntegrationType,IntegrationUri]' --output text 2>/dev/null || echo "unknown")
            echo "    Sample orphaned: $sample_uri"

            if $DRY_RUN; then
                log_info "[DRY RUN] Would delete $orphaned_count orphaned integrations from '$api_name'"
                continue
            fi

            read -rp "    Delete $orphaned_count orphaned integrations from '$api_name'? (y/n): " confirm < /dev/tty
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                log_warn "Skipping '$api_name'."
                continue
            fi

            deleted=0
            for oid in "${orphaned_ids[@]}"; do
                set +e
                aws apigatewayv2 delete-integration --api-id "$api_id" \
                    --integration-id "$oid" --region "$region" 2>/dev/null
                rc=$?
                set -e
                if [[ $rc -eq 0 ]]; then
                    deleted=$((deleted + 1))
                fi
            done
            total_deleted=$((total_deleted + deleted))
            log_info "Deleted $deleted of $orphaned_count orphaned integrations from '$api_name'"

        done <<< "$HTTP_APIS"
    done

    # Also check for duplicate/orphaned HTTP APIs in DR region
    log_step "Checking for duplicate HTTP APIs in $DEST_REGION"

    DR_HTTP_APIS=$(aws apigatewayv2 get-apis --region "$DEST_REGION" \
        --query 'Items[].[ApiId,Name]' --output text 2>/dev/null || echo "")

    DR_HTTP_JSON=$(aws apigatewayv2 get-apis --region "$DEST_REGION" \
        --query 'Items[]' --output json 2>/dev/null || echo "[]")

    if [[ "$(echo "$DR_HTTP_JSON" | jq 'length')" -gt 0 ]]; then
        # Find duplicate names using jq
        dup_names=$(echo "$DR_HTTP_JSON" | jq -r '[.[].Name] | group_by(.) | map(select(length > 1)) | .[][][]' 2>/dev/null | sort -u)

        if [[ -n "$dup_names" ]]; then
            while IFS= read -r dup_name; do
                [[ -z "$dup_name" ]] && continue
                count=$(echo "$DR_HTTP_JSON" | jq --arg n "$dup_name" '[.[] | select(.Name==$n)] | length')
                log_warn "Duplicate API: '$dup_name' — $count copies in $DEST_REGION"
                echo "    Keep the latest and delete the rest:"

                echo "$DR_HTTP_JSON" | jq -r --arg n "$dup_name" \
                    '.[] | select(.Name==$n) | "\(.ApiId)\t\(.CreatedDate // "unknown")"' | \
                    sort -t$'\t' -k2 | while IFS=$'\t' read -r dup_id created; do
                    echo "      $dup_id (created: $created)"
                    echo "        aws apigatewayv2 delete-api --api-id $dup_id --region $DEST_REGION"
                done
            done <<< "$dup_names"
        else
            log_info "No duplicate HTTP APIs in $DEST_REGION"
        fi
    else
        log_info "No HTTP APIs in $DEST_REGION"
    fi

    # Summary
    echo ""
    divider
    echo -e "${BOLD}  Cleanup Summary${NC}"
    divider
    echo "    Orphaned integrations found  : $total_orphaned"
    echo "    Orphaned integrations deleted : $total_deleted"
    divider
}

# ── Main ──────────────────────────────────────────────────
case "$COMMAND" in
    audit)      cmd_audit ;;
    dynamodb)   cmd_dynamodb ;;
    lambda)     cmd_lambda ;;
    apigateway) cmd_apigateway ;;
    cleanup)    cmd_cleanup ;;
    *)
        log_error "Unknown command: $COMMAND"
        echo "  Valid commands: audit, dynamodb, lambda, apigateway, cleanup"
        exit 1
        ;;
esac

echo ""
