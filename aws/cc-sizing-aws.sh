#!/usr/bin/env bash
# =============================================================================
#  Cortex Cloud - Workload sizing per AWS
#
#  Conta le risorse AWS e le converte in workload secondo la
#  Cortex Cloud Metering Guide (Palo Alto Networks).
#
#  - Usa solo la AWS CLI v2 (filtri JMESPath con --query): non serve jq.
#  - Scansiona TUTTE le regioni abilitate di ogni account.
#  - Conta solo le istanze in esecuzione (con -s include anche le stopped).
#  - I nodi EKS/ECS su EC2 sono gia' istanze EC2: vengono mostrati a parte
#    solo come informazione, senza contarli due volte.
#  - L'arrotondamento per eccesso si applica sul TOTALE di ogni categoria,
#    non account per account.
#  - Ogni chiamata fallita viene registrata e segnalata nel riepilogo.
#
#  Uso: ./cc-sizing-aws.sh [-o] [-r ruolo] [-n regione] [-s] [-f file.csv] [-h]
# =============================================================================
set -u

ORG_MODE=false
ROLE="OrganizationAccountAccessRole"
ONLY_REGION=""
INCLUDE_STOPPED=false
CSV_FILE="cortex-sizing-aws-$(date +%Y%m%d-%H%M).csv"

# Rapporti di conversione (Cortex Cloud Metering Guide)
RATIO_CAAS=10          # container gestiti per 1 workload
RATIO_SERVERLESS=25    # funzioni serverless per 1 workload
RATIO_BUCKET=10        # bucket per 1 workload
RATIO_PAAS=2           # database PaaS per 1 workload
TB_PER_DBAAS=1         # TB archiviati DBaaS per 1 workload
IMG_FREE_PER_WL=10     # scansioni immagini gratuite per workload VM/CaaS
RATIO_IMAGES=10        # scansioni oltre la quota per 1 workload

usage() {
  cat <<EOF
Uso: $0 [opzioni]

  -o            Modalita' Organization: scansiona tutti gli account ACTIVE
                assumendo un ruolo cross-account (da lanciare nel management account)
  -r <ruolo>    Ruolo da assumere negli account membri (default: $ROLE)
  -n <regione>  Scansiona una sola regione (es. eu-west-1)
  -s            Includi anche le istanze EC2 in stato 'stopped'
  -f <file>     Nome del file CSV di dettaglio (default: $CSV_FILE)
  -h            Mostra questo aiuto

Permessi minimi: ReadOnlyAccess (o SecurityAudit + ViewOnlyAccess) in ogni account;
in modalita' -o anche organizations:ListAccounts e sts:AssumeRole.
EOF
  exit 0
}

while getopts ":or:n:sf:h" opt; do
  case $opt in
    o) ORG_MODE=true ;;
    r) ROLE="$OPTARG" ;;
    n) ONLY_REGION="$OPTARG" ;;
    s) INCLUDE_STOPPED=true ;;
    f) CSV_FILE="$OPTARG" ;;
    h) usage ;;
    :) echo "L'opzione -$OPTARG richiede un valore" >&2; exit 1 ;;
    *) echo "Opzione non valida: -$OPTARG" >&2; exit 1 ;;
  esac
done

command -v aws >/dev/null 2>&1 || { echo "Errore: AWS CLI non trovata." >&2; exit 1; }

ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG" "$ERRLOG.tmp"' EXIT

STATES="running"
$INCLUDE_STOPPED && STATES="running,stopped"

# -----------------------------------------------------------------------------
# Helper
# -----------------------------------------------------------------------------
log_err() { echo "[$1] $2" >> "$ERRLOG"; }

# Esegue una chiamata aws che restituisce un numero (query con length()/sum()).
# In caso di errore registra il problema e restituisce 0.
#   n <contesto> aws-args...
n() {
  local ctx=$1; shift
  local out
  if out=$(aws "$@" --output json 2>"$ERRLOG.tmp"); then
    out=${out//[[:space:]]/}
    [[ "$out" =~ ^[0-9]+(\.[0-9]+)?$ ]] || out=0
    printf '%s' "${out%%.*}"
  else
    log_err "$ctx" "$(head -c 300 "$ERRLOG.tmp" | tr '\n' ' ')"
    printf '0'
  fi
}

# Esegue una chiamata aws che restituisce una lista (output text, separata da spazi/tab/a capo).
#   l <contesto> aws-args...
l() {
  local ctx=$1; shift
  local out
  if out=$(aws "$@" --output text 2>"$ERRLOG.tmp"); then
    [[ "$out" == "None" ]] && out=""
    printf '%s' "$out"
  else
    log_err "$ctx" "$(head -c 300 "$ERRLOG.tmp" | tr '\n' ' ')"
  fi
}

ceil_div() { # ceil_div <numeratore> <denominatore>
  local a=$1 b=$2
  (( a <= 0 )) && { echo 0; return; }
  echo $(( (a + b - 1) / b ))
}

# -----------------------------------------------------------------------------
# Totali globali (grezzi, prima della conversione in workload)
# -----------------------------------------------------------------------------
T_EC2=0; T_EKS_NODES=0; T_LAMBDA=0; T_FARGATE_CONT=0; T_APPRUNNER=0
T_ECR_IMAGES=0; T_S3=0; T_RDS=0; T_AURORA_INST=0; T_AURORA_SLS=0
T_REDSHIFT=0; T_DDB_TABLES=0; T_DDB_BYTES=0; T_ACCOUNTS=0

echo "account,region,ec2_instances,of_which_eks_nodes,lambda_functions,fargate_containers,apprunner_services,ecr_images,s3_buckets,rds_instances,of_which_aurora,aurora_serverless_v1_clusters,redshift_clusters,dynamodb_tables,dynamodb_bytes" > "$CSV_FILE"

# -----------------------------------------------------------------------------
# Conteggio per una singola regione
# -----------------------------------------------------------------------------
scan_region() {
  local acct=$1 r=$2

  local ec2 eks lambda fargate=0 apprunner ecr=0 rds aurora aurora_sls redshift ddb_tables=0 ddb_bytes=0

  # EC2 (istanze, non reservation)
  ec2=$(n "$acct/$r ec2" ec2 describe-instances --region "$r" \
        --filters "Name=instance-state-name,Values=$STATES" \
        --query 'length(Reservations[].Instances[])')
  # di cui nodi EKS (solo informativo, gia' inclusi in ec2)
  eks=$(n "$acct/$r eks-nodes" ec2 describe-instances --region "$r" \
        --filters "Name=instance-state-name,Values=$STATES" "Name=tag-key,Values=eks:cluster-name,kubernetes.io/cluster/*" \
        --query 'length(Reservations[].Instances[])')

  # Lambda
  lambda=$(n "$acct/$r lambda" lambda list-functions --region "$r" --query 'length(Functions)')

  # ECS Fargate: container nei task in esecuzione
  local clusters cl tasks batch t count
  clusters=$(l "$acct/$r ecs-clusters" ecs list-clusters --region "$r" --query 'clusterArns[]')
  for cl in $clusters; do
    tasks=$(l "$acct/$r ecs-tasks" ecs list-tasks --region "$r" --cluster "$cl" \
            --launch-type FARGATE --desired-status RUNNING --query 'taskArns[]')
    batch=()
    for t in $tasks; do
      batch+=("$t")
      if (( ${#batch[@]} == 100 )); then
        count=$(n "$acct/$r ecs-describe" ecs describe-tasks --region "$r" --cluster "$cl" \
                --tasks "${batch[@]}" --query 'length(tasks[].containers[])')
        fargate=$((fargate + count)); batch=()
      fi
    done
    if (( ${#batch[@]} > 0 )); then
      count=$(n "$acct/$r ecs-describe" ecs describe-tasks --region "$r" --cluster "$cl" \
              --tasks "${batch[@]}" --query 'length(tasks[].containers[])')
      fargate=$((fargate + count))
    fi
  done

  # App Runner (servizio non disponibile in tutte le regioni: errore ignorato)
  apprunner=$(aws apprunner list-services --region "$r" --query 'length(ServiceSummaryList)' --output json 2>/dev/null)
  [[ "$apprunner" =~ ^[0-9]+$ ]] || apprunner=0

  # ECR: immagini (manifest) in ogni repository
  local repos repo imgs
  repos=$(l "$acct/$r ecr-repos" ecr describe-repositories --region "$r" --query 'repositories[].repositoryName')
  for repo in $repos; do
    imgs=$(n "$acct/$r ecr-images" ecr describe-images --region "$r" --repository-name "$repo" --query 'length(imageDetails)')
    ecr=$((ecr + imgs))
  done

  # Database PaaS: tutte le istanze RDS (MySQL, PostgreSQL, MariaDB, Oracle, SQL Server,
  # Aurora, DocumentDB, Neptune) + cluster Aurora Serverless v1 (che non hanno istanze)
  rds=$(n "$acct/$r rds" rds describe-db-instances --region "$r" --query 'length(DBInstances)')
  aurora=$(n "$acct/$r rds-aurora" rds describe-db-instances --region "$r" \
           --query "length(DBInstances[?starts_with(Engine, 'aurora')])")
  aurora_sls=$(n "$acct/$r rds-aurora-sls" rds describe-db-clusters --region "$r" \
               --query "length(DBClusters[?EngineMode=='serverless'])")
  redshift=$(n "$acct/$r redshift" redshift describe-clusters --region "$r" --query 'length(Clusters)')

  # DynamoDB (DBaaS): numero di tabelle e byte archiviati
  local tables tb bytes
  tables=$(l "$acct/$r dynamodb" dynamodb list-tables --region "$r" --query 'TableNames[]')
  for tb in $tables; do
    ddb_tables=$((ddb_tables + 1))
    bytes=$(n "$acct/$r dynamodb-size" dynamodb describe-table --region "$r" --table-name "$tb" --query 'Table.TableSizeBytes')
    ddb_bytes=$((ddb_bytes + bytes))
  done

  local any=$((ec2 + lambda + fargate + apprunner + ecr + rds + aurora_sls + redshift + ddb_tables))
  if (( any > 0 )); then
    printf '    %-16s EC2 %-5s (EKS %s)  Lambda %-5s Fargate cont. %-4s ECR img %-6s RDS %-4s Redshift %-3s DynamoDB %s\n' \
      "$r" "$ec2" "$eks" "$lambda" "$fargate" "$ecr" "$rds" "$redshift" "$ddb_tables"
  fi
  echo "$acct,$r,$ec2,$eks,$lambda,$fargate,$apprunner,$ecr,,$rds,$aurora,$aurora_sls,$redshift,$ddb_tables,$ddb_bytes" >> "$CSV_FILE"

  T_EC2=$((T_EC2 + ec2)); T_EKS_NODES=$((T_EKS_NODES + eks)); T_LAMBDA=$((T_LAMBDA + lambda))
  T_FARGATE_CONT=$((T_FARGATE_CONT + fargate)); T_APPRUNNER=$((T_APPRUNNER + apprunner))
  T_ECR_IMAGES=$((T_ECR_IMAGES + ecr)); T_RDS=$((T_RDS + rds)); T_AURORA_INST=$((T_AURORA_INST + aurora))
  T_AURORA_SLS=$((T_AURORA_SLS + aurora_sls)); T_REDSHIFT=$((T_REDSHIFT + redshift))
  T_DDB_TABLES=$((T_DDB_TABLES + ddb_tables)); T_DDB_BYTES=$((T_DDB_BYTES + ddb_bytes))
}

# -----------------------------------------------------------------------------
# Conteggio per un account
# -----------------------------------------------------------------------------
scan_account() {
  local acct=$1 regions r s3
  echo ""
  echo "== Account $acct"

  if [[ -n "$ONLY_REGION" ]]; then
    regions=$ONLY_REGION
  else
    regions=$(aws account list-regions --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT \
              --query 'Regions[].RegionName' --output text 2>/dev/null)
    [[ -z "$regions" || "$regions" == "None" ]] && \
      regions=$(l "$acct regions" ec2 describe-regions --query 'Regions[].RegionName')
  fi
  if [[ -z "$regions" ]]; then
    log_err "$acct" "impossibile ottenere l'elenco delle regioni: account saltato"
    return
  fi

  # S3 e' globale: una sola chiamata per account
  s3=$(n "$acct s3" s3api list-buckets --query 'length(Buckets)')
  echo "    S3 bucket (globali): $s3"
  echo "$acct,global,,,,,,,$s3,,,,,," >> "$CSV_FILE"
  T_S3=$((T_S3 + s3))

  for r in $regions; do
    scan_region "$acct" "$r"
  done
  T_ACCOUNTS=$((T_ACCOUNTS + 1))
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
CALLER=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "Errore: credenziali AWS non configurate o non valide (aws sts get-caller-identity)." >&2; exit 1; }

echo "Cortex Cloud - sizing AWS"
echo "Stati EC2 conteggiati: $STATES"

if $ORG_MODE; then
  ACCOUNTS=$(aws organizations list-accounts --query "Accounts[?Status=='ACTIVE'].Id" --output text 2>"$ERRLOG.tmp") || {
    echo "Errore: impossibile elencare gli account dell'organizzazione:" >&2; cat "$ERRLOG.tmp" >&2; exit 1; }
  echo "Modalita' Organization, ruolo: $ROLE"
  for acct in $ACCOUNTS; do
    if [[ "$acct" == "$CALLER" ]]; then
      scan_account "$acct"      # account corrente: credenziali attuali
      continue
    fi
    creds=$(aws sts assume-role --role-arn "arn:aws:iam::${acct}:role/${ROLE}" --role-session-name cortex-sizing \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>"$ERRLOG.tmp")
    if [[ $? -ne 0 || -z "$creds" ]]; then
      log_err "$acct" "assume-role fallito, account NON conteggiato: $(head -c 200 "$ERRLOG.tmp" | tr '\n' ' ')"
      echo ""; echo "== Account $acct: impossibile assumere il ruolo, saltato"
      continue
    fi
    read -r AK SK ST <<< "$creds"
    AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    scan_account "$acct"
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  done
else
  scan_account "$CALLER"
fi

# -----------------------------------------------------------------------------
# Conversione in workload (arrotondamento sul totale)
# -----------------------------------------------------------------------------
W_VM=$T_EC2
CAAS_UNITS=$((T_FARGATE_CONT + T_APPRUNNER))
W_CAAS=$(ceil_div "$CAAS_UNITS" "$RATIO_CAAS")
W_SERVERLESS=$(ceil_div "$T_LAMBDA" "$RATIO_SERVERLESS")
W_BUCKET=$(ceil_div "$T_S3" "$RATIO_BUCKET")
PAAS_UNITS=$((T_RDS + T_AURORA_SLS + T_REDSHIFT))
W_PAAS=$(ceil_div "$PAAS_UNITS" "$RATIO_PAAS")
TB_UNIT=$(( TB_PER_DBAAS * 1000 * 1000 * 1000 * 1000 ))
W_DBAAS=$(ceil_div "$T_DDB_BYTES" "$TB_UNIT")
IMG_FREE=$(( (W_VM + W_CAAS) * IMG_FREE_PER_WL ))
IMG_OVER=$(( T_ECR_IMAGES - IMG_FREE )); (( IMG_OVER < 0 )) && IMG_OVER=0
W_IMAGES=$(ceil_div "$IMG_OVER" "$RATIO_IMAGES")
W_TOTAL=$((W_VM + W_CAAS + W_SERVERLESS + W_BUCKET + W_PAAS + W_DBAAS + W_IMAGES))
DDB_GB=$(awk -v b="$T_DDB_BYTES" 'BEGIN{printf "%.1f", b/1e9}')

echo ""
echo "============================================================================"
echo " RIEPILOGO CORTEX CLOUD - AWS   (account scansionati: $T_ACCOUNTS)"
echo "============================================================================"
printf ' %-38s %12s %8s %10s\n' "Categoria" "Risorse" "Rapporto" "Workload"
printf ' %-38s %12s %8s %10s\n' "VM (EC2, $STATES)" "$T_EC2" "1" "$W_VM"
printf ' %-38s %12s %8s %10s\n' "  di cui nodi EKS (gia' inclusi)" "$T_EKS_NODES" "" "-"
printf ' %-38s %12s %8s %10s\n' "CaaS (container Fargate + App Runner)" "$CAAS_UNITS" "10" "$W_CAAS"
printf ' %-38s %12s %8s %10s\n' "Serverless (Lambda)" "$T_LAMBDA" "25" "$W_SERVERLESS"
printf ' %-38s %12s %8s %10s\n' "Cloud bucket (S3)" "$T_S3" "10" "$W_BUCKET"
printf ' %-38s %12s %8s %10s\n' "DB PaaS (RDS, Redshift, Aurora SLS v1)" "$PAAS_UNITS" "2" "$W_PAAS"
printf ' %-38s %12s %8s %10s\n' "  di cui istanze Aurora" "$T_AURORA_INST" "" "-"
printf ' %-38s %12s %8s %10s\n' "DBaaS (DynamoDB, $T_DDB_TABLES tabelle) GB" "$DDB_GB" "1 TB" "$W_DBAAS"
printf ' %-38s %12s %8s %10s\n' "Immagini ECR (quota gratuita $IMG_FREE)" "$T_ECR_IMAGES" "10" "$W_IMAGES"
echo "----------------------------------------------------------------------------"
printf ' %-38s %12s %8s %10s\n' "TOTALE WORKLOAD AWS" "" "" "$W_TOTAL"
echo "============================================================================"
echo " Non calcolati da questo script: utenti SaaS, asset Cloud ASM non gestiti,"
echo " pod EKS su Fargate (servono kubectl), Amazon Keyspaces e altri DBaaS."
echo " Aurora e' contato per istanza (writer + reader): verificare con Palo Alto."
echo " Dettaglio per account/regione: $CSV_FILE"

NERR=$(wc -l < "$ERRLOG")
if (( NERR > 0 )); then
  echo ""
  echo " ATTENZIONE: $NERR chiamate non riuscite (i relativi conteggi valgono 0)."
  echo " Prime 20:"
  head -20 "$ERRLOG" | sed 's/^/   /'
  cp "$ERRLOG" "${CSV_FILE%.csv}-errori.log"
  echo " Elenco completo: ${CSV_FILE%.csv}-errori.log"
fi
