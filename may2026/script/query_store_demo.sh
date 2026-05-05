#!/usr/bin/env bash
set -euo pipefail

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf "Required command '%s' is not installed or not on PATH.\n" "$command_name"
    exit 1
  fi
}

require_command az
require_command curl
require_command psql

az extension add --name monitor-control-service --only-show-errors >/dev/null 2>&1 || true

if ! az account show >/dev/null 2>&1; then
  printf "Azure CLI is not authenticated. Run 'az login' first.\n"
  exit 1
fi

if [[ -n "${SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID" --only-show-errors
fi

timestamp=$(date +%Y%m%d%H%M%S)
BASE_NAME=${BASE_NAME:-pgqswait${timestamp}}
RESOURCE_GROUP=${RESOURCE_GROUP:-rg-${BASE_NAME}}
LOCATION=${LOCATION:-southeastasia}
PRIMARY_SERVER=${PRIMARY_SERVER:-${BASE_NAME}-primary}
REPLICA_1=${REPLICA_1:-${BASE_NAME}-readreplica}
REPLICA_2=${REPLICA_2:-${BASE_NAME}-cascadereadreplica}
LOG_ANALYTICS_WORKSPACE=${LOG_ANALYTICS_WORKSPACE:-law-${BASE_NAME}}
LOG_ANALYTICS_LOCATION=${LOG_ANALYTICS_LOCATION:-southeastasia}
ADMIN_USER=${ADMIN_USER:-pgadmin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-}
SKU_NAME=${SKU_NAME:-Standard_D4ds_v5}
TIER=${TIER:-GeneralPurpose}
STORAGE_SIZE=${STORAGE_SIZE:-64}
VERSION=${VERSION:-17}
PRIMARY_DATABASE=${PRIMARY_DATABASE:-postgres}
SQL_BASE_URL=${SQL_BASE_URL:-https://raw.githubusercontent.com/nachoalonsoportillo/query-store-blog/refs/heads/main/may2026}
TPCH_DDL_URL=${TPCH_DDL_URL:-${SQL_BASE_URL}/schema/tpch_ddl.sql}
WORKLOAD_REPETITIONS=${WORKLOAD_REPETITIONS:-10}
AUTO_APPROVE=$(printf '%s' "${AUTO_APPROVE:-false}" | tr '[:upper:]' '[:lower:]')

if [[ -z "$ADMIN_PASSWORD" ]]; then
  printf "Set ADMIN_PASSWORD before running this script.\n"
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+$ ]] || (( VERSION < 14 )); then
  printf "Cascading read replicas require PostgreSQL version 14 or later. Current VERSION=%s.\n" "$VERSION"
  exit 1
fi

if [[ "$TIER" == "Burstable" ]]; then
  printf "Read replicas are not supported on the Burstable tier. Use GeneralPurpose or MemoryOptimized.\n"
  exit 1
fi

if [[ ! "$WORKLOAD_REPETITIONS" =~ ^[0-9]+$ ]] || (( WORKLOAD_REPETITIONS < 5 )); then
  printf "WORKLOAD_REPETITIONS must be an integer greater than or equal to 5. Current value=%s.\n" "$WORKLOAD_REPETITIONS"
  exit 1
fi

server_exists() {
  local rg="$1"
  local server_name="$2"
  az postgres flexible-server show \
    --resource-group "$rg" \
    --name "$server_name" \
    --only-show-errors >/dev/null 2>&1
}

open_firewall_for_server() {
  local rg="$1"
  local server_name="$2"
  local rule_name="allow-all"
  

  printf "Creating firewall rule '%s' on server %s to allow connections from all IP addresses...\n" "$rule_name" "$server_name"
  az postgres flexible-server firewall-rule create \
    --resource-group "$rg" \
    --name "$server_name" \
    --rule-name "$rule_name" \
    --start-ip-address 0.0.0.0 \
    --end-ip-address 255.255.255.255 \
    --only-show-errors >/dev/null
}

configure_diagnostics_for_server() {
  local rg="$1"
  local server_name="$2"
  local workspace_id="$3"
  local setting_name="send-query-store-logs-to-laws"
  local server_resource_id

  server_resource_id=$(az postgres flexible-server show \
    --resource-group "$rg" \
    --name "$server_name" \
    --query id \
    --output tsv \
    --only-show-errors)

  printf "Configuring diagnostic settings on server %s to send query store logs to the Log Analytics workspace using resource-specific tables...\n" "$server_name"
  az monitor diagnostic-settings create \
    --name "$setting_name" \
    --resource "$server_resource_id" \
    --workspace "$workspace_id" \
    --export-to-resource-specific true \
    --logs '[{"category":"PostgreSQLFlexQueryStoreRuntime","enabled":true},{"category":"PostgreSQLFlexQueryStoreWaitStats","enabled":true},{"category":"PostgreSQLQueryStoreSqlText","enabled":true}]' \
    --only-show-errors >/dev/null
}

configure_query_store_for_server() {
  local rg="$1"
  local server_name="$2"

  printf "Setting query store parameters on server %s...\n" "$server_name"
  az postgres flexible-server parameter set \
    --resource-group "$rg" \
    --server-name "$server_name" \
    --name pg_qs.interval_length_minutes \
    --value 1 \
    --only-show-errors >/dev/null

  az postgres flexible-server parameter set \
    --resource-group "$rg" \
    --server-name "$server_name" \
    --name pg_qs.query_capture_mode \
    --value all \
    --only-show-errors >/dev/null

  az postgres flexible-server parameter set \
    --resource-group "$rg" \
    --server-name "$server_name" \
    --name pg_qs.parameters_capture_mode \
    --value capture_first_sample \
    --only-show-errors >/dev/null

  az postgres flexible-server parameter set \
    --resource-group "$rg" \
    --server-name "$server_name" \
    --name pg_qs.emit_query_text \
    --value on \
    --only-show-errors >/dev/null
}

configure_index_tuning_for_server() {
  local rg="$1"
  local server_name="$2"

  printf "Setting index_tuning.mode on server %s...\n" "$server_name"
  az postgres flexible-server parameter set \
    --resource-group "$rg" \
    --server-name "$server_name" \
    --name index_tuning.mode \
    --value report \
    --only-show-errors >/dev/null
}

download_and_execute_sql_against_server() {
  local rg="$1"
  local server_name="$2"
  local database_name="$3"
  local sql_url="$4"
  local server_fqdn
  local sql_file

  server_fqdn=$(az postgres flexible-server show \
    --resource-group "$rg" \
    --name "$server_name" \
    --query fullyQualifiedDomainName \
    --output tsv \
    --only-show-errors)

  sql_file=$(mktemp)
  trap "rm -f \"$sql_file\"" RETURN

  printf "Downloading SQL from %s...\n" "$sql_url"
  curl -fsSL "$sql_url" -o "$sql_file"

  printf "Executing %s against server %s, database %s...\n" "$sql_url" "$server_name" "$database_name"
  PGPASSWORD="$ADMIN_PASSWORD" psql \
    "host=$server_fqdn port=5432 dbname=$database_name user=$ADMIN_USER sslmode=require" \
    --set ON_ERROR_STOP=1 \
    --quiet \
    --file "$sql_file"
}

run_sql_file_multiple_times() {
  local rg="$1"
  local server_name="$2"
  local database_name="$3"
  local sql_url="$4"
  local repetitions="${5:-5}"
  local run_number

  for ((run_number = 1; run_number <= repetitions; run_number++)); do
    printf "Run %s/%s for %s on server %s...\n" "$run_number" "$repetitions" "$sql_url" "$server_name"
    download_and_execute_sql_against_server "$rg" "$server_name" "$database_name" "$sql_url"
  done
}

for server_name in "$PRIMARY_SERVER" "$REPLICA_1" "$REPLICA_2"; do
  if server_exists "$RESOURCE_GROUP" "$server_name"; then
    printf "Server %s already exists in resource group %s. Choose a different BASE_NAME or server name.\n" "$server_name" "$RESOURCE_GROUP"
    exit 1
  fi
done

printf "About to provision the following demo environment:\n"
printf "  Resource group : %s\n" "$RESOURCE_GROUP"
printf "  Location       : %s\n" "$LOCATION"
printf "  Primary        : %s\n" "$PRIMARY_SERVER"
printf "  Replica level1 : %s\n" "$REPLICA_1"
printf "  Replica level2 : %s\n" "$REPLICA_2"
printf "  Log Analytics  : %s\n" "$LOG_ANALYTICS_WORKSPACE"
printf "  LAWS location  : %s\n" "$LOG_ANALYTICS_LOCATION"
printf "  Database       : %s\n" "$PRIMARY_DATABASE"
printf "  TPC-H Schema   : %s\n" "$TPCH_DDL_URL"
printf "  TPC-H data     : %s\n" "customer.sql, lineitem.sql, nation.sql, orders.sql, part.sql, partsupp.sql, region.sql, supplier.sql"
printf "  TPC-H workload : %s\n" "workload1 on all; workload2 on primary; workload3 on replica1; workload4 on replica2; workload5 on primary+replica1; workload6 on primary+replica2; workload7 on replica1+replica2"
printf "  Repetitions    : %s\n" "$WORKLOAD_REPETITIONS"
printf "  Version/Tier   : PostgreSQL %s / %s\n" "$VERSION" "$TIER"
printf "  SKU            : %s\n" "$SKU_NAME"

if [[ "$AUTO_APPROVE" != "true" ]]; then
  read -r -p "Proceed with provisioning? [y/N] " confirmation
  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    printf "Aborted.\n"
    exit 0
  fi
fi

process_start_epoch=$(date +%s)

printf "Creating resource group %s in %s...\n" "$RESOURCE_GROUP" "$LOCATION"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags Scenario=QueryStore Demo=ReplicaChain \
  --only-show-errors >/dev/null

printf "Creating Log Analytics workspace %s in %s...\n" "$LOG_ANALYTICS_WORKSPACE" "$LOG_ANALYTICS_LOCATION"
az monitor log-analytics workspace create \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LOG_ANALYTICS_WORKSPACE" \
  --location "$LOG_ANALYTICS_LOCATION" \
  --sku PerGB2018 \
  --tags Scenario=QueryStore Demo=ReplicaChain \
  --only-show-errors >/dev/null

workspaceResourceId=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LOG_ANALYTICS_WORKSPACE" \
  --query id \
  --output tsv \
  --only-show-errors)

printf "Creating primary PostgreSQL flexible server %s...\n" "$PRIMARY_SERVER"
az postgres flexible-server create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PRIMARY_SERVER" \
  --location "$LOCATION" \
  --admin-user "$ADMIN_USER" \
  --admin-password "$ADMIN_PASSWORD" \
  --sku-name "$SKU_NAME" \
  --tier "$TIER" \
  --storage-size "$STORAGE_SIZE" \
  --version "$VERSION" \
  --high-availability Disabled \
  --public-access Enabled \
  --tags Scenario=QueryStore Demo=ReplicaChain \
  --only-show-errors

open_firewall_for_server "$RESOURCE_GROUP" "$PRIMARY_SERVER"
configure_diagnostics_for_server "$RESOURCE_GROUP" "$PRIMARY_SERVER" "$workspaceResourceId"
configure_query_store_for_server "$RESOURCE_GROUP" "$PRIMARY_SERVER"
configure_index_tuning_for_server "$RESOURCE_GROUP" "$PRIMARY_SERVER"
download_and_execute_sql_against_server "$RESOURCE_GROUP" "$PRIMARY_SERVER" "$PRIMARY_DATABASE" "$TPCH_DDL_URL"

for sql_name in customer.sql lineitem.sql nation.sql orders.sql part.sql partsupp.sql region.sql supplier.sql; do
  printf "Processing data file: %s...\n" "$sql_name"
  download_and_execute_sql_against_server "$RESOURCE_GROUP" "$PRIMARY_SERVER" "$PRIMARY_DATABASE" "${SQL_BASE_URL}/data/${sql_name}"
done

printf "Creating first-level read replica %s from %s...\n" "$REPLICA_1" "$PRIMARY_SERVER"
az postgres flexible-server replica create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$REPLICA_1" \
  --source-server "$PRIMARY_SERVER" \
  --location "$LOCATION" \
  --yes \
  --only-show-errors

open_firewall_for_server "$RESOURCE_GROUP" "$REPLICA_1"
configure_diagnostics_for_server "$RESOURCE_GROUP" "$REPLICA_1" "$workspaceResourceId"
configure_query_store_for_server "$RESOURCE_GROUP" "$REPLICA_1"

printf "Creating second-level read replica %s from %s...\n" "$REPLICA_2" "$REPLICA_1"
az postgres flexible-server replica create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$REPLICA_2" \
  --source-server "$REPLICA_1" \
  --location "$LOCATION" \
  --yes \
  --only-show-errors

open_firewall_for_server "$RESOURCE_GROUP" "$REPLICA_2"
configure_diagnostics_for_server "$RESOURCE_GROUP" "$REPLICA_2" "$workspaceResourceId"
configure_query_store_for_server "$RESOURCE_GROUP" "$REPLICA_2"

printf "Running workload query scripts across the primary and replicas %s times each...\n" "$WORKLOAD_REPETITIONS"
for server_name in "$PRIMARY_SERVER" "$REPLICA_1" "$REPLICA_2"; do
  run_sql_file_multiple_times "$RESOURCE_GROUP" "$server_name" "$PRIMARY_DATABASE" "${SQL_BASE_URL}/workload/workload1.sql" "$WORKLOAD_REPETITIONS"
done

run_sql_file_multiple_times "$RESOURCE_GROUP" "$PRIMARY_SERVER" "$PRIMARY_DATABASE" "${SQL_BASE_URL}/workload/workload2.sql" "$WORKLOAD_REPETITIONS"
run_sql_file_multiple_times "$RESOURCE_GROUP" "$REPLICA_1" "$PRIMARY_DATABASE" "${SQL_BASE_URL}/workload/workload3.sql" "$WORKLOAD_REPETITIONS"
run_sql_file_multiple_times "$RESOURCE_GROUP" "$REPLICA_2" "$PRIMARY_DATABASE" "${SQL_BASE_URL}/workload/workload4.sql" "$WORKLOAD_REPETITIONS"

for server_name in "$PRIMARY_SERVER" "$REPLICA_1"; do
  run_sql_file_multiple_times "$RESOURCE_GROUP" "$server_name" "$PRIMARY_DATABASE" "${SQL_BASE_URL}/workload/workload5.sql" "$WORKLOAD_REPETITIONS"
done

for server_name in "$PRIMARY_SERVER" "$REPLICA_2"; do
  run_sql_file_multiple_times "$RESOURCE_GROUP" "$server_name" "$PRIMARY_DATABASE" "${SQL_BASE_URL}/workload/workload6.sql" "$WORKLOAD_REPETITIONS"
done

for server_name in "$REPLICA_1" "$REPLICA_2"; do
  run_sql_file_multiple_times "$RESOURCE_GROUP" "$server_name" "$PRIMARY_DATABASE" "${SQL_BASE_URL}/workload/workload7.sql" "$WORKLOAD_REPETITIONS"
done

printf "\nReplica chain created successfully.\n"
printf "  Primary : %s\n" "$PRIMARY_SERVER"
printf "  Replica : %s -> source %s\n" "$REPLICA_1" "$PRIMARY_SERVER"
printf "  Replica : %s -> source %s\n" "$REPLICA_2" "$REPLICA_1"
printf "  Logs    : %s\n" "$LOG_ANALYTICS_WORKSPACE"
printf "  Diag    : allLogs enabled on primary and both replicas using resource-specific tables\n"
printf "  Query   : pg_qs.parameters_capture_mode=capture_first_sample, pg_qs.emit_query_text=on\n"
printf "  SQL     : downloaded and executed from %s against %s\n" "$TPCH_DDL_URL" "$PRIMARY_SERVER"
printf "  SQL     : also executed customer.sql, lineitem.sql, nation.sql, orders.sql, part.sql, partsupp.sql, region.sql, and supplier.sql from %s against %s\n" "$SQL_BASE_URL/data" "$PRIMARY_SERVER"
printf "  SQL     : workload1 on all three; workload2 on primary; workload3 on replica1; workload4 on replica2; workload5 on primary+replica1; workload6 on primary+replica2; workload7 on replica1+replica2\n"
printf "  SQL     : each workload query above was executed %s times\n" "$WORKLOAD_REPETITIONS"
process_end_epoch=$(date +%s)
process_duration_seconds=$((process_end_epoch - process_start_epoch))
process_duration_minutes=$((process_duration_seconds / 60))
process_duration_remaining_seconds=$((process_duration_seconds % 60))
printf "  Time    : total elapsed %02d:%02d (%s seconds)\n" \
  "$process_duration_minutes" \
  "$process_duration_remaining_seconds" \
  "$process_duration_seconds"
printf "\nTo clean up later, run:\n"
printf "  az group delete --name %s --yes --no-wait\n" "$RESOURCE_GROUP"
