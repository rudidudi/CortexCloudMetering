#!/usr/bin/env bash
# =============================================================================
#  Cortex Cloud - Workload sizing per Azure
#
#  Conta le risorse Azure e le converte in workload secondo la
#  Cortex Cloud Metering Guide (Palo Alto Networks).
#
#  - Usa solo la Azure CLI (filtri JMESPath con --query): non serve jq.
#  - Scansiona tutte le subscription abilitate (o solo quella indicata con -u).
#  - Conta solo le VM in esecuzione (con -s include anche le deallocate).
#  - I nodi AKS sono istanze di VM Scale Set: vengono contati una sola volta.
#  - Le immagini nei registry applicano la quota gratuita.
#  - L'arrotondamento per eccesso si applica sul TOTALE di ogni categoria,
#    non subscription per subscription.
#  - Ogni chiamata fallita viene registrata e segnalata nel riepilogo.
#
#  Uso: ./cc-sizing-azure.sh [-u subscription] [-n location] [-s] [-f file.csv] [-h]
# =============================================================================
set -u

ONLY_SUB=""
ONLY_LOC=""
INCLUDE_STOPPED=false
CSV_FILE="cortex-sizing-azure-$(date +%Y%m%d-%H%M).csv"

RATIO_CAAS=10; RATIO_SERVERLESS=25; RATIO_BUCKET=10; RATIO_PAAS=2
IMG_FREE_PER_WL=10; RATIO_IMAGES=10

usage() {
  cat <<EOF
Uso: $0 [opzioni]

  -u <id|nome>  Scansiona una sola subscription (default: tutte quelle abilitate)
  -n <location> Conta solo le risorse in una location (es. westeurope)
  -s            Includi anche le VM deallocate (stopped)
  -f <file>     Nome del file CSV di dettaglio (default: $CSV_FILE)
  -h            Mostra questo aiuto

Permessi minimi: ruolo Reader sulle subscription (o sul Management Group).
Per contare le immagini in ACR serve anche AcrPull / Reader sui registry
e raggiungibilita' di rete del registry (registry privati possono fallire).
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
    :) echo "L'opzione -$OPTARG richiede un valore" >&2; exit 1 ;;
    *) echo "Opzione non valida: -$OPTARG" >&2; exit 1 ;;
  esac
done

command -v az >/dev/null 2>&1 || { echo "Errore: Azure CLI non trovata." >&2; exit 1; }
# Installa al volo le estensioni necessarie (containerapp) senza modificare la config dell'utente
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=yes_without_prompt
export AZURE_CORE_ONLY_SHOW_ERRORS=true

ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG" "$ERRLOG.tmp"' EXIT

log_err() { echo "[$1] $2" >> "$ERRLOG"; }

# Filtro location da aggiungere alle query JMESPath
LOCF=""
[[ -n "$ONLY_LOC" ]] && LOCF="?location=='$ONLY_LOC'"

# n <contesto> az-args...   -> numero (query con length()/sum()); 0 in caso di errore
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

# l <contesto> az-args...   -> lista (una voce per riga)
l() {
  local ctx=$1; shift
  local out
  if out=$(az "$@" -o tsv 2>"$ERRLOG.tmp"); then
    printf '%s' "$out"
  else
    log_err "$ctx" "$(head -c 300 "$ERRLOG.tmp" | tr '\n' ' ')"
  fi
}

ceil_div() { local a=$1 b=$2; (( a <= 0 )) && { echo 0; return; }; echo $(( (a + b - 1) / b )); }

T_VM=0; T_VMSS=0; T_AKS=0; T_FUNC=0; T_ACI=0; T_ACA=0; T_ACR=0
T_STORAGE=0; T_SQL=0; T_SQLDB=0; T_SQLMI=0; T_PGFLEX=0; T_MYFLEX=0; T_COSMOS=0; T_SUBS=0

echo "subscription,vm,vmss_uniform_instances,of_which_aks_nodes,functions,aci_containers,containerapp_containers,acr_images,storage_accounts,sql_servers,sql_databases,sql_managed_instances,postgres_flexible,mysql_flexible,cosmosdb_accounts" > "$CSV_FILE"

scan_sub() {
  local sub=$1 name=$2 S=(--subscription "$1")
  echo ""
  echo "== Subscription $name ($sub)"

  # --- VM "classiche" (incluse quelle dei VMSS in modalita' Flexible) ---
  local vmq="length([${LOCF:+$LOCF}])"
  if ! $INCLUDE_STOPPED; then
    if [[ -n "$ONLY_LOC" ]]; then vmq="length([?location=='$ONLY_LOC' && powerState=='VM running'])"
    else vmq="length([?powerState=='VM running'])"; fi
  fi
  local vm; vm=$(n "$name vm" vm list -d "${S[@]}" --query "$vmq")

  # --- Istanze VMSS Uniform (comprendono i nodi AKS) ---
  local vmssq="sum([?orchestrationMode=='Uniform'].sku.capacity)"
  [[ -n "$ONLY_LOC" ]] && vmssq="sum([?orchestrationMode=='Uniform' && location=='$ONLY_LOC'].sku.capacity)"
  local vmss; vmss=$(n "$name vmss" vmss list "${S[@]}" --query "$vmssq")

  # --- di cui nodi AKS (solo informativo, gia' inclusi in vmss) ---
  local aksq="sum([].agentPoolProfiles[].count)"
  [[ -n "$ONLY_LOC" ]] && aksq="sum([?location=='$ONLY_LOC'].agentPoolProfiles[].count)"
  local aks; aks=$(n "$name aks" aks list "${S[@]}" --query "$aksq")

  # --- Azure Functions: singole funzioni dentro ogni Function App ---
  local func=0 apps rg fname cnt
  apps=$(l "$name functionapp" functionapp list "${S[@]}" --query "[${LOCF:+$LOCF}].[name,resourceGroup]")
  while IFS=$'\t' read -r fname rg; do
    [[ -z "$fname" ]] && continue
    cnt=$(az functionapp function list -n "$fname" -g "$rg" "${S[@]}" --query "length(@)" -o tsv 2>"$ERRLOG.tmp")
    if [[ "$cnt" =~ ^[0-9]+$ ]] && (( cnt > 0 )); then
      func=$((func + cnt))
    else
      # app ferma o non leggibile: conta almeno 1 funzione e segnala
      func=$((func + 1))
      log_err "$name functions" "funzioni non leggibili per l'app $fname: conteggiata come 1"
    fi
  done <<< "$apps"

  # --- CaaS: container ACI e container delle Container Apps ---
  local aci aca
  aci=$(n "$name aci" container list "${S[@]}" --query "length([${LOCF:+$LOCF}].containers[])")
  aca=$(n "$name containerapp" containerapp list "${S[@]}" --query "length([${LOCF:+$LOCF}].properties.template.containers[])")

  # --- Immagini in Azure Container Registry ---
  local acr=0 regs reg repos repo imgs
  regs=$(l "$name acr" acr list "${S[@]}" --query "[${LOCF:+$LOCF}].name")
  for reg in $regs; do
    repos=$(l "$name acr/$reg repos" acr repository list -n "$reg" "${S[@]}")
    for repo in $repos; do
      imgs=$(n "$name acr/$reg/$repo" acr manifest list-metadata -r "$reg" -n "$repo" "${S[@]}" --query "length(@)")
      acr=$((acr + imgs))
    done
  done

  # --- Storage account (equivalente dei bucket) ---
  local st; st=$(n "$name storage" storage account list "${S[@]}" --query "length([${LOCF:+$LOCF}])")

  # --- Database PaaS ---
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
  cosmos=$(n "$name cosmosdb" cosmosdb list "${S[@]}" --query "length([${LOCF:+$LOCF}])")

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
az account show >/dev/null 2>&1 || { echo "Errore: Azure CLI non autenticata. Esegui 'az login'." >&2; exit 1; }

echo "Cortex Cloud - sizing Azure"
if $INCLUDE_STOPPED; then echo "VM conteggiate: running + deallocated"; else echo "VM conteggiate: solo running"; fi

if [[ -n "$ONLY_SUB" ]]; then
  SUBS=$(az account show --subscription "$ONLY_SUB" --query "[id,name]" -o tsv 2>/dev/null | paste -sd'\t' -)
  [[ -z "$SUBS" ]] && { echo "Errore: subscription '$ONLY_SUB' non trovata." >&2; exit 1; }
else
  SUBS=$(az account list --query "[?state=='Enabled'].[id,name]" -o tsv)
fi
[[ -z "$SUBS" ]] && { echo "Nessuna subscription abilitata trovata." >&2; exit 1; }

while IFS=$'\t' read -r sid sname; do
  [[ -z "$sid" ]] && continue
  scan_sub "$sid" "$sname"
done <<< "$SUBS"

# -----------------------------------------------------------------------------
# Conversione in workload (arrotondamento sul totale)
# -----------------------------------------------------------------------------
W_VM=$((T_VM + T_VMSS))
CAAS_UNITS=$((T_ACI + T_ACA))
W_CAAS=$(ceil_div "$CAAS_UNITS" "$RATIO_CAAS")
W_SERVERLESS=$(ceil_div "$T_FUNC" "$RATIO_SERVERLESS")
W_BUCKET=$(ceil_div "$T_STORAGE" "$RATIO_BUCKET")
PAAS_UNITS=$((T_SQLDB + T_SQLMI + T_PGFLEX + T_MYFLEX))
W_PAAS=$(ceil_div "$PAAS_UNITS" "$RATIO_PAAS")
IMG_FREE=$(( (W_VM + W_CAAS) * IMG_FREE_PER_WL ))
IMG_OVER=$(( T_ACR - IMG_FREE )); (( IMG_OVER < 0 )) && IMG_OVER=0
W_IMAGES=$(ceil_div "$IMG_OVER" "$RATIO_IMAGES")
W_TOTAL=$((W_VM + W_CAAS + W_SERVERLESS + W_BUCKET + W_PAAS + W_IMAGES))

echo ""
echo "============================================================================"
echo " RIEPILOGO CORTEX CLOUD - AZURE   (subscription scansionate: $T_SUBS)"
echo "============================================================================"
printf ' %-40s %10s %8s %10s\n' "Categoria" "Risorse" "Rapporto" "Workload"
printf ' %-40s %10s %8s %10s\n' "VM (Virtual Machines)" "$T_VM" "1" "$T_VM"
printf ' %-40s %10s %8s %10s\n' "VM Scale Set (istanze Uniform)" "$T_VMSS" "1" "$T_VMSS"
printf ' %-40s %10s %8s %10s\n' "  di cui nodi AKS (gia' inclusi)" "$T_AKS" "" "-"
printf ' %-40s %10s %8s %10s\n' "CaaS (container ACI + Container Apps)" "$CAAS_UNITS" "10" "$W_CAAS"
printf ' %-40s %10s %8s %10s\n' "Serverless (Azure Functions)" "$T_FUNC" "25" "$W_SERVERLESS"
printf ' %-40s %10s %8s %10s\n' "Cloud bucket (Storage account)" "$T_STORAGE" "10" "$W_BUCKET"
printf ' %-40s %10s %8s %10s\n' "DB PaaS (SQL DB, SQL MI, PG, MySQL)" "$PAAS_UNITS" "2" "$W_PAAS"
printf ' %-40s %10s %8s %10s\n' "  (server SQL logici: $T_SQL)" "" "" ""
printf ' %-40s %10s %8s %10s\n' "Immagini ACR (quota gratuita $IMG_FREE)" "$T_ACR" "10" "$W_IMAGES"
echo "----------------------------------------------------------------------------"
printf ' %-40s %10s %8s %10s\n' "TOTALE WORKLOAD AZURE" "" "" "$W_TOTAL"
echo "============================================================================"
echo " Cosmos DB: $T_COSMOS account -> DBaaS, si licenzia a TB archiviato:"
echo "   aggiungere a mano (Azure Monitor, metrica 'DataUsage')."
echo " Non calcolati: utenti SaaS, asset Cloud ASM non gestiti, pod su virtual node AKS."
echo " Verificare con Palo Alto: DB SQL contati per database (non per server) e"
echo "   storage account usati come equivalente dei bucket."
echo " Dettaglio per subscription: $CSV_FILE"

NERR=$(wc -l < "$ERRLOG")
if (( NERR > 0 )); then
  echo ""
  echo " ATTENZIONE: $NERR chiamate non riuscite (i relativi conteggi valgono 0)."
  echo " Prime 20:"
  head -20 "$ERRLOG" | sed 's/^/   /'
  cp "$ERRLOG" "${CSV_FILE%.csv}-errori.log"
  echo " Elenco completo: ${CSV_FILE%.csv}-errori.log"
fi
