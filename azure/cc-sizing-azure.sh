#!/usr/bin/env bash
# =============================================================================
#  Cortex Cloud - Azure workload sizing
#
#  Counts Azure resources and converts them into workloads according to the
#  Cortex Cloud Metering Guide (Palo Alto Networks).
#
#  - Uses only the Azure CLI (JMESPath filters via --query): jq is not needed.
#  - Scans every enabled subscription (or only the one passed with -u).
#  - Counts running VMs only (-s also includes deallocated ones).
#  - AKS nodes are VM Scale Set instances: they are counted only once.
#  - Registry images take the free quota into account.
#  - Rounding up is applied to the TOTAL of each category, not per subscription.
#  - Every failed API call is logged and reported in the summary.
#
#  Usage: ./cc-sizing-azure.sh [-u subscription] [-n location] [-s] [-f file.csv] [-h]
# =============================================================================
set -u

ONLY_SUB=""
ONLY_LOC=""
INCLUDE_STOPPED=false
CSV_FILE="cortex-sizing-azure-$(date +%Y%m%d-%H%M).csv"

# Conversion ratios (Cortex Cloud Metering Guide)
RATIO_CAAS=10          # managed containers per workload
RATIO_SERVERLESS=25    # serverless functions per workload
RATIO_BUCKET=10        # cloud buckets (storage accounts) per workload
RATIO_PAAS=2           # PaaS databases per workload
IMG_FREE_PER_WL=10     # free image scans per deployed VM/CaaS workload
RATIO_IMAGES=10        # image scans beyond the free quota per workload

usage() {
  cat <<EOF
Usage: $0 [options]

  -u <id|name>  Scan a single subscription (default: every enabled subscription)
  -n <location> Count only resources in one location (e.g. westeurope)
  -s            Also include deallocated (stopped) VMs
  -f <file>     Name of the detailed CSV file (default: $CSV_FILE)
  -h            Show this help

Minimum permissions: Reader role on the subscriptions (or on the Management Group).
Counting ACR images also requires AcrPull / Reader on the registries and network
reachability of the registry (private registries may fail).
EOF
  exit 0
}

while getopts ":u:n:sf:h" opt; do
  case $opt in
    u) ONLY_SUB="$OPTARG" ;;
    n) ONLY_LOC="$OPTARG" ;;
    s) INCLUDE_STOPPED=true ;;
    f) CSV_FILE="$OPTARG" ;;
    h) usage ;;
    :) echo "Option -$OPTARG requires a value" >&2; exit 1 ;;
    *) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done

command -v az >/dev/null 2>&1 || { echo "Error: Azure CLI not found." >&2; exit 1; }
# Install required extensions (containerapp) on the fly without touching the user's config
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=yes_without_prompt
export AZURE_CORE_ONLY_SHOW_ERRORS=true

ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG" "$ERRLOG.tmp"' EXIT

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log_err() { echo "[$1] $2" >> "$ERRLOG"; }

# Progress line: on a terminal it is rewritten in place, otherwise (e.g. output
# redirected to a file) each step is printed on its own line.
IS_TTY=false
[[ -t 1 ]] && IS_TTY=true
progress() {
  if $IS_TTY; then printf '\r\033[K  %s' "$*"; else echo "  $*"; fi
}
clear_progress() {
  $IS_TTY && printf '\r\033[K'
  return 0
}

# Optional location filter injected into JMESPath queries
LOCF=""
[[ -n "$ONLY_LOC" ]] && LOCF="?location=='$ONLY_LOC'"

# Runs an az call that returns a number (query using length()/sum()).
# On failure it logs the problem and returns 0.
#   n <context> az-args...
n() {
  local ctx=$1; shift
  local out
  if out=$(az "$@" -o tsv 2>"$ERRLOG.tmp"); then
    out=${out//[[:space:]]/}
    [[ "$out" =~ ^[0-9]+(\.[0-9]+)?$ ]] || out=0
    printf '%s' "${out%%.*}"
  else
    log_err "$ctx" "$(head -c 300 "$ERRLOG.tmp" | tr '\n' ' ')"
    printf '0'
  fi
}

# Runs an az call that returns a list (one item per line).
#   l <context> az-args...
l() {
  local ctx=$1; shift
  local out
  if out=$(az "$@" -o tsv 2>"$ERRLOG.tmp"); then
    printf '%s' "$out"
  else
    log_err "$ctx" "$(head -c 300 "$ERRLOG.tmp" | tr '\n' ' ')"
  fi
}

ceil_div() { # ceil_div <numerator> <denominator>
  local a=$1 b=$2
  (( a <= 0 )) && { echo 0; return; }
  echo $(( (a + b - 1) / b ))
}

# -----------------------------------------------------------------------------
# Global totals (raw resource counts, before workload conversion)
# -----------------------------------------------------------------------------
T_VM=0; T_VMSS=0; T_AKS=0; T_FUNC=0; T_ACI=0; T_ACA=0; T_ACR=0
T_STORAGE=0; T_SQL=0; T_SQLDB=0; T_SQLMI=0; T_PGFLEX=0; T_MYFLEX=0; T_COSMOS=0; T_SUBS=0

echo "subscription,vm,vmss_uniform_instances,of_which_aks_nodes,functions,aci_containers,containerapp_containers,acr_images,storage_accounts,sql_servers,sql_databases,sql_managed_instances,postgres_flexible,mysql_flexible,cosmosdb_accounts" > "$CSV_FILE"

# -----------------------------------------------------------------------------
# Count resources in a single subscription
# -----------------------------------------------------------------------------
scan_sub() {
  local sub=$1 name=$2 S=(--subscription "$1") tag="[$3/$4] $2"
  echo ""
  echo "== Subscription $name ($sub) [$3/$4]"

  progress "$tag: Virtual Machines..."
  # --- Standalone VMs (including VMs of Flexible-mode scale sets) ---
  # 'vm list -d' adds powerState so stopped/deallocated VMs can be filtered out
  local vmq="length([${LOCF:+$LOCF}])"
  if ! $INCLUDE_STOPPED; then
    if [[ -n "$ONLY_LOC" ]]; then vmq="length([?location=='$ONLY_LOC' && powerState=='VM running'])"
    else vmq="length([?powerState=='VM running'])"; fi
  fi
  local vm; vm=$(n "$name vm" vm list -d "${S[@]}" --query "$vmq")

  progress "$tag: VM Scale Sets / AKS..."
  # --- Uniform VM Scale Set instances (include AKS nodes) ---
  # Flexible scale sets are excluded here because their VMs already show up in 'vm list'
  local vmssq="sum([?orchestrationMode=='Uniform'].sku.capacity)"
  [[ -n "$ONLY_LOC" ]] && vmssq="sum([?orchestrationMode=='Uniform' && location=='$ONLY_LOC'].sku.capacity)"
  local vmss; vmss=$(n "$name vmss" vmss list "${S[@]}" --query "$vmssq")

  # --- Of which AKS nodes (informational only, already included in vmss) ---
  local aksq="sum([].agentPoolProfiles[].count)"
  [[ -n "$ONLY_LOC" ]] && aksq="sum([?location=='$ONLY_LOC'].agentPoolProfiles[].count)"
  local aks; aks=$(n "$name aks" aks list "${S[@]}" --query "$aksq")

  progress "$tag: Function Apps..."
  # --- Azure Functions: individual functions inside every Function App ---
  local func=0 apps rg fname cnt
  apps=$(l "$name functionapp" functionapp list "${S[@]}" --query "[${LOCF:+$LOCF}].[name,resourceGroup]")
  while IFS=$'\t' read -r fname rg; do
    [[ -z "$fname" ]] && continue
    progress "$tag: Function App $fname..."
    cnt=$(az functionapp function list -n "$fname" -g "$rg" "${S[@]}" --query "length(@)" -o tsv 2>"$ERRLOG.tmp")
    if [[ "$cnt" =~ ^[0-9]+$ ]] && (( cnt > 0 )); then
      func=$((func + cnt))
    else
      # Stopped or unreadable app: count at least 1 function and report it
      func=$((func + 1))
      log_err "$name functions" "functions not readable for app $fname: counted as 1"
    fi
  done <<< "$apps"

  progress "$tag: Container Instances / Container Apps..."
  # --- CaaS: ACI containers and Container Apps containers ---
  local aci aca
  aci=$(n "$name aci" container list "${S[@]}" --query "length([${LOCF:+$LOCF}].containers[])")
  aca=$(n "$name containerapp" containerapp list "${S[@]}" --query "length([${LOCF:+$LOCF}].properties.template.containers[])")

  progress "$tag: ACR images..."
  # --- Images (manifests) in Azure Container Registry ---
  local acr=0 regs reg repos repo imgs
  regs=$(l "$name acr" acr list "${S[@]}" --query "[${LOCF:+$LOCF}].name")
  for reg in $regs; do
    repos=$(l "$name acr/$reg repos" acr repository list -n "$reg" "${S[@]}")
    for repo in $repos; do
      progress "$tag: ACR $reg/$repo..."
      imgs=$(n "$name acr/$reg/$repo" acr manifest list-metadata -r "$reg" -n "$repo" "${S[@]}" --query "length(@)")
      acr=$((acr + imgs))
    done
  done

  progress "$tag: Storage accounts..."
  # --- Storage accounts (used as the cloud bucket equivalent) ---
  local st; st=$(n "$name storage" storage account list "${S[@]}" --query "length([${LOCF:+$LOCF}])")

  progress "$tag: databases..."
  # --- PaaS databases ---
  # Azure SQL is counted per database (excluding 'master'); logical servers are reported too
  local sql=0 sqldb=0 servers srv srg d
  servers=$(l "$name sql" sql server list "${S[@]}" --query "[${LOCF:+$LOCF}].[name,resourceGroup]")
  while IFS=$'\t' read -r srv srg; do
    [[ -z "$srv" ]] && continue
    sql=$((sql + 1))
    d=$(n "$name sql/$srv db" sql db list -s "$srv" -g "$srg" "${S[@]}" --query "length([?name!='master'])")
    sqldb=$((sqldb + d))
  done <<< "$servers"
  local sqlmi pg my cosmos
  sqlmi=$(n "$name sql-mi" sql mi list "${S[@]}" --query "length([${LOCF:+$LOCF}])")
  pg=$(n "$name postgres" postgres flexible-server list "${S[@]}" --query "length([${LOCF:+$LOCF}])")
  my=$(n "$name mysql" mysql flexible-server list "${S[@]}" --query "length([${LOCF:+$LOCF}])")
  # Cosmos DB is DBaaS (licensed per TB stored): only the account count is reported
  cosmos=$(n "$name cosmosdb" cosmosdb list "${S[@]}" --query "length([${LOCF:+$LOCF}])")

  clear_progress
  printf '    VM %s | VMSS %s (AKS %s) | Functions %s | ACI %s | ContainerApps %s | ACR img %s | Storage %s | SQL srv %s (db %s) | SQL MI %s | PG %s | MySQL %s | Cosmos %s\n' \
    "$vm" "$vmss" "$aks" "$func" "$aci" "$aca" "$acr" "$st" "$sql" "$sqldb" "$sqlmi" "$pg" "$my" "$cosmos"
  echo "$sub,$vm,$vmss,$aks,$func,$aci,$aca,$acr,$st,$sql,$sqldb,$sqlmi,$pg,$my,$cosmos" >> "$CSV_FILE"

  T_VM=$((T_VM + vm)); T_VMSS=$((T_VMSS + vmss)); T_AKS=$((T_AKS + aks)); T_FUNC=$((T_FUNC + func))
  T_ACI=$((T_ACI + aci)); T_ACA=$((T_ACA + aca)); T_ACR=$((T_ACR + acr)); T_STORAGE=$((T_STORAGE + st))
  T_SQL=$((T_SQL + sql)); T_SQLDB=$((T_SQLDB + sqldb)); T_SQLMI=$((T_SQLMI + sqlmi))
  T_PGFLEX=$((T_PGFLEX + pg)); T_MYFLEX=$((T_MYFLEX + my)); T_COSMOS=$((T_COSMOS + cosmos))
  T_SUBS=$((T_SUBS + 1))
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
az account show >/dev/null 2>&1 || { echo "Error: Azure CLI not logged in. Run 'az login'." >&2; exit 1; }

echo "Cortex Cloud - Azure sizing"
if $INCLUDE_STOPPED; then echo "VMs counted: running + deallocated"; else echo "VMs counted: running only"; fi

if [[ -n "$ONLY_SUB" ]]; then
  SUBS=$(az account show --subscription "$ONLY_SUB" --query "[id,name]" -o tsv 2>/dev/null | paste -sd'\t' -)
  [[ -z "$SUBS" ]] && { echo "Error: subscription '$ONLY_SUB' not found." >&2; exit 1; }
else
  SUBS=$(az account list --query "[?state=='Enabled'].[id,name]" -o tsv)
fi
[[ -z "$SUBS" ]] && { echo "No enabled subscription found." >&2; exit 1; }

NSUB=$(grep -c . <<< "$SUBS"); ISUB=0
while IFS=$'\t' read -r sid sname; do
  [[ -z "$sid" ]] && continue
  ISUB=$((ISUB + 1))
  scan_sub "$sid" "$sname" "$ISUB" "$NSUB"
done <<< "$SUBS"

# -----------------------------------------------------------------------------
# Workload conversion (rounding applied to totals)
# -----------------------------------------------------------------------------
W_VM=$((T_VM + T_VMSS))
CAAS_UNITS=$((T_ACI + T_ACA))
W_CAAS=$(ceil_div "$CAAS_UNITS" "$RATIO_CAAS")
W_SERVERLESS=$(ceil_div "$T_FUNC" "$RATIO_SERVERLESS")
W_BUCKET=$(ceil_div "$T_STORAGE" "$RATIO_BUCKET")
PAAS_UNITS=$((T_SQLDB + T_SQLMI + T_PGFLEX + T_MYFLEX))
W_PAAS=$(ceil_div "$PAAS_UNITS" "$RATIO_PAAS")
# Container images: only scans beyond the free quota are billable
IMG_FREE=$(( (W_VM + W_CAAS) * IMG_FREE_PER_WL ))
IMG_OVER=$(( T_ACR - IMG_FREE )); (( IMG_OVER < 0 )) && IMG_OVER=0
W_IMAGES=$(ceil_div "$IMG_OVER" "$RATIO_IMAGES")
W_TOTAL=$((W_VM + W_CAAS + W_SERVERLESS + W_BUCKET + W_PAAS + W_IMAGES))

echo ""
echo "============================================================================"
echo " CORTEX CLOUD SUMMARY - AZURE   (subscriptions scanned: $T_SUBS)"
echo "============================================================================"
printf ' %-40s %10s %8s %10s\n' "Category" "Resources" "Ratio" "Workloads"
printf ' %-40s %10s %8s %10s\n' "VM (Virtual Machines)" "$T_VM" "1" "$T_VM"
printf ' %-40s %10s %8s %10s\n' "VM Scale Sets (Uniform instances)" "$T_VMSS" "1" "$T_VMSS"
printf ' %-40s %10s %8s %10s\n' "  of which AKS nodes (already incl.)" "$T_AKS" "" "-"
printf ' %-40s %10s %8s %10s\n' "CaaS (ACI + Container Apps containers)" "$CAAS_UNITS" "10" "$W_CAAS"
printf ' %-40s %10s %8s %10s\n' "Serverless (Azure Functions)" "$T_FUNC" "25" "$W_SERVERLESS"
printf ' %-40s %10s %8s %10s\n' "Cloud buckets (Storage accounts)" "$T_STORAGE" "10" "$W_BUCKET"
printf ' %-40s %10s %8s %10s\n' "PaaS DB (SQL DB, SQL MI, PG, MySQL)" "$PAAS_UNITS" "2" "$W_PAAS"
printf ' %-40s %10s %8s %10s\n' "  (SQL logical servers: $T_SQL)" "" "" ""
printf ' %-40s %10s %8s %10s\n' "ACR images (free quota $IMG_FREE)" "$T_ACR" "10" "$W_IMAGES"
echo "----------------------------------------------------------------------------"
printf ' %-40s %10s %8s %10s\n' "TOTAL AZURE WORKLOADS" "" "" "$W_TOTAL"
echo "============================================================================"
echo " Cosmos DB: $T_COSMOS accounts -> DBaaS, licensed per TB stored:"
echo "   add manually (Azure Monitor, 'DataUsage' metric)."
echo " Not counted: SaaS users, unmanaged Cloud ASM assets, pods on AKS virtual nodes."
echo " Confirm with Palo Alto: SQL counted per database (not per server) and"
echo "   storage accounts used as the bucket equivalent."
echo " Per subscription details: $CSV_FILE"

NERR=$(wc -l < "$ERRLOG")
if (( NERR > 0 )); then
  echo ""
  echo " WARNING: $NERR calls failed (the related counts are 0)."
  echo " First 20:"
  head -20 "$ERRLOG" | sed 's/^/   /'
  cp "$ERRLOG" "${CSV_FILE%.csv}-errors.log"
  echo " Full list: ${CSV_FILE%.csv}-errors.log"
fi
