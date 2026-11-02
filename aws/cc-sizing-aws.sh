#!/usr/bin/env bash
# =============================================================================
#  Cortex Cloud - AWS workload sizing
#
#  Counts AWS resources and converts them into workloads according to the
#  Cortex Cloud Metering Guide (Palo Alto Networks).
#
#  - Uses only the AWS CLI v2 (JMESPath filters via --query): jq is not needed.
#  - Scans ALL enabled regions of every account.
#  - Counts running instances only (-s also includes stopped ones).
#  - EKS/ECS nodes on EC2 are already EC2 instances: they are shown separately
#    for information only and are never counted twice.
#  - Rounding up is applied to the TOTAL of each category, not per account.
#  - Every failed API call is logged and reported in the summary.
#
#  Usage: ./cc-sizing-aws.sh [-o] [-r role] [-n region] [-s] [-f file.csv] [-h]
# =============================================================================
set -u

ORG_MODE=false
ROLE="OrganizationAccountAccessRole"
ONLY_REGION=""
INCLUDE_STOPPED=false
CSV_FILE="cortex-sizing-aws-$(date +%Y%m%d-%H%M).csv"

# Conversion ratios (Cortex Cloud Metering Guide)
RATIO_CAAS=10          # managed containers per workload
RATIO_SERVERLESS=25    # serverless functions per workload
RATIO_BUCKET=10        # cloud buckets per workload
RATIO_PAAS=2           # PaaS databases per workload
TB_PER_DBAAS=1         # DBaaS TB stored per workload
IMG_FREE_PER_WL=10     # free image scans per deployed VM/CaaS workload
RATIO_IMAGES=10        # image scans beyond the free quota per workload

usage() {
  cat <<EOF
Usage: $0 [options]

  -o            Organization mode: scan every ACTIVE account by assuming a
                cross-account role (run it from the management account)
  -r <role>     Role to assume in member accounts (default: $ROLE)
  -n <region>   Scan a single region (e.g. eu-west-1)
  -s            Also include EC2 instances in 'stopped' state
  -f <file>     Name of the detailed CSV file (default: $CSV_FILE)
  -h            Show this help

Minimum permissions: ReadOnlyAccess (or SecurityAudit + ViewOnlyAccess) in every
account; in -o mode also organizations:ListAccounts and sts:AssumeRole.
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
    :) echo "Option -$OPTARG requires a value" >&2; exit 1 ;;
    *) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done

command -v aws >/dev/null 2>&1 || { echo "Error: AWS CLI not found." >&2; exit 1; }

ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG" "$ERRLOG.tmp"' EXIT

STATES="running"
$INCLUDE_STOPPED && STATES="running,stopped"

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

# Runs an aws call that returns a number (query using length()/sum()).
# On failure it logs the problem and returns 0.
#   n <context> aws-args...
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

# Runs an aws call that returns a list (text output, whitespace separated).
#   l <context> aws-args...
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

ceil_div() { # ceil_div <numerator> <denominator>
  local a=$1 b=$2
  (( a <= 0 )) && { echo 0; return; }
  echo $(( (a + b - 1) / b ))
}

# -----------------------------------------------------------------------------
# Global totals (raw resource counts, before workload conversion)
# -----------------------------------------------------------------------------
T_EC2=0; T_EKS_NODES=0; T_LAMBDA=0; T_FARGATE_CONT=0; T_APPRUNNER=0
T_ECR_IMAGES=0; T_S3=0; T_RDS=0; T_AURORA_INST=0; T_AURORA_SLS=0
T_REDSHIFT=0; T_DDB_TABLES=0; T_DDB_BYTES=0; T_ACCOUNTS=0

echo "account,region,ec2_instances,of_which_eks_nodes,lambda_functions,fargate_containers,apprunner_services,ecr_images,s3_buckets,rds_instances,of_which_aurora,aurora_serverless_v1_clusters,redshift_clusters,dynamodb_tables,dynamodb_bytes" > "$CSV_FILE"

# -----------------------------------------------------------------------------
# Count resources in a single region
# -----------------------------------------------------------------------------
scan_region() {
  local acct=$1 r=$2 tag="[$3/$4] $2"

  local ec2 eks lambda fargate=0 apprunner ecr=0 rds aurora aurora_sls redshift ddb_tables=0 ddb_bytes=0

  progress "$tag: EC2..."
  # EC2: count instances, not reservations (one reservation can hold many instances)
  ec2=$(n "$acct/$r ec2" ec2 describe-instances --region "$r" \
        --filters "Name=instance-state-name,Values=$STATES" \
        --query 'length(Reservations[].Instances[])')
  # Of which EKS nodes (informational only, already included in ec2)
  eks=$(n "$acct/$r eks-nodes" ec2 describe-instances --region "$r" \
        --filters "Name=instance-state-name,Values=$STATES" "Name=tag-key,Values=eks:cluster-name,kubernetes.io/cluster/*" \
        --query 'length(Reservations[].Instances[])')

  progress "$tag: Lambda..."
  # Lambda functions
  lambda=$(n "$acct/$r lambda" lambda list-functions --region "$r" --query 'length(Functions)')

  progress "$tag: ECS Fargate / App Runner..."
  # ECS Fargate: containers inside running tasks (describe-tasks accepts max 100 tasks per call)
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

  # App Runner (not available in every region: errors are ignored on purpose)
  apprunner=$(aws apprunner list-services --region "$r" --query 'length(ServiceSummaryList)' --output json 2>/dev/null)
  [[ "$apprunner" =~ ^[0-9]+$ ]] || apprunner=0

  progress "$tag: ECR images..."
  # ECR: images (manifests) in every repository
  local repos repo imgs k=0 nrepos
  repos=$(l "$acct/$r ecr-repos" ecr describe-repositories --region "$r" --query 'repositories[].repositoryName')
  nrepos=$(wc -w <<< "$repos")
  for repo in $repos; do
    k=$((k + 1))
    progress "$tag: ECR images (repository $k/$nrepos)..."
    imgs=$(n "$acct/$r ecr-images" ecr describe-images --region "$r" --repository-name "$repo" --query 'length(imageDetails)')
    ecr=$((ecr + imgs))
  done

  progress "$tag: RDS / Redshift..."
  # PaaS databases: every RDS instance (MySQL, PostgreSQL, MariaDB, Oracle, SQL Server,
  # Aurora, DocumentDB, Neptune) + Aurora Serverless v1 clusters (which have no instances)
  rds=$(n "$acct/$r rds" rds describe-db-instances --region "$r" --query 'length(DBInstances)')
  aurora=$(n "$acct/$r rds-aurora" rds describe-db-instances --region "$r" \
           --query "length(DBInstances[?starts_with(Engine, 'aurora')])")
  aurora_sls=$(n "$acct/$r rds-aurora-sls" rds describe-db-clusters --region "$r" \
               --query "length(DBClusters[?EngineMode=='serverless'])")
  redshift=$(n "$acct/$r redshift" redshift describe-clusters --region "$r" --query 'length(Clusters)')

  progress "$tag: DynamoDB..."
  # DynamoDB (DBaaS): number of tables and bytes stored
  local tables tb bytes ntables
  tables=$(l "$acct/$r dynamodb" dynamodb list-tables --region "$r" --query 'TableNames[]')
  ntables=$(wc -w <<< "$tables")
  for tb in $tables; do
    progress "$tag: DynamoDB (table $((ddb_tables + 1))/$ntables)..."
    ddb_tables=$((ddb_tables + 1))
    bytes=$(n "$acct/$r dynamodb-size" dynamodb describe-table --region "$r" --table-name "$tb" --query 'Table.TableSizeBytes')
    ddb_bytes=$((ddb_bytes + bytes))
  done

  clear_progress
  # Print only regions that contain something
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
# Count resources in a single account
# -----------------------------------------------------------------------------
scan_account() {
  local acct=$1 label=${2:-} regions r s3 i=0 nreg
  echo ""
  echo "== Account $acct${label:+ ($label)}"

  if [[ -n "$ONLY_REGION" ]]; then
    regions=$ONLY_REGION
  else
    # Enabled regions can differ per account (opt-in regions), so they are read per account
    regions=$(aws account list-regions --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT \
              --query 'Regions[].RegionName' --output text 2>/dev/null)
    [[ -z "$regions" || "$regions" == "None" ]] && \
      regions=$(l "$acct regions" ec2 describe-regions --query 'Regions[].RegionName')
  fi
  if [[ -z "$regions" ]]; then
    log_err "$acct" "unable to list regions: account skipped"
    return
  fi

  # S3 is global: a single call per account
  progress "S3 buckets..."
  s3=$(n "$acct s3" s3api list-buckets --query 'length(Buckets)')
  clear_progress
  echo "    S3 buckets (global): $s3"
  echo "$acct,global,,,,,,,$s3,,,,,," >> "$CSV_FILE"
  T_S3=$((T_S3 + s3))

  nreg=$(wc -w <<< "$regions")
  for r in $regions; do
    i=$((i + 1))
    scan_region "$acct" "$r" "$i" "$nreg"
  done
  clear_progress
  echo "    Regions scanned: $nreg"
  T_ACCOUNTS=$((T_ACCOUNTS + 1))
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
CALLER=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "Error: AWS credentials missing or invalid (aws sts get-caller-identity)." >&2; exit 1; }

echo "Cortex Cloud - AWS sizing"
echo "EC2 states counted: $STATES"

if $ORG_MODE; then
  ACCOUNTS=$(aws organizations list-accounts --query "Accounts[?Status=='ACTIVE'].Id" --output text 2>"$ERRLOG.tmp") || {
    echo "Error: unable to list organization accounts:" >&2; cat "$ERRLOG.tmp" >&2; exit 1; }
  echo "Organization mode, role: $ROLE"
  NACC=$(wc -w <<< "$ACCOUNTS"); IACC=0
  for acct in $ACCOUNTS; do
    IACC=$((IACC + 1))
    if [[ "$acct" == "$CALLER" ]]; then
      scan_account "$acct" "$IACC/$NACC"      # current account: use the current credentials
      continue
    fi
    creds=$(aws sts assume-role --role-arn "arn:aws:iam::${acct}:role/${ROLE}" --role-session-name cortex-sizing \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>"$ERRLOG.tmp")
    if [[ $? -ne 0 || -z "$creds" ]]; then
      log_err "$acct" "assume-role failed, account NOT counted: $(head -c 200 "$ERRLOG.tmp" | tr '\n' ' ')"
      echo ""; echo "== Account $acct ($IACC/$NACC): unable to assume role, skipped"
      continue
    fi
    read -r AK SK ST <<< "$creds"
    AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    scan_account "$acct" "$IACC/$NACC"
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  done
else
  scan_account "$CALLER"
fi

# -----------------------------------------------------------------------------
# Workload conversion (rounding applied to totals)
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
# Container images: only scans beyond the free quota are billable
IMG_FREE=$(( (W_VM + W_CAAS) * IMG_FREE_PER_WL ))
IMG_OVER=$(( T_ECR_IMAGES - IMG_FREE )); (( IMG_OVER < 0 )) && IMG_OVER=0
W_IMAGES=$(ceil_div "$IMG_OVER" "$RATIO_IMAGES")
W_TOTAL=$((W_VM + W_CAAS + W_SERVERLESS + W_BUCKET + W_PAAS + W_DBAAS + W_IMAGES))
DDB_GB=$(awk -v b="$T_DDB_BYTES" 'BEGIN{printf "%.1f", b/1e9}')

echo ""
echo "============================================================================"
echo " CORTEX CLOUD SUMMARY - AWS   (accounts scanned: $T_ACCOUNTS)"
echo "============================================================================"
printf ' %-38s %12s %8s %10s\n' "Category" "Resources" "Ratio" "Workloads"
printf ' %-38s %12s %8s %10s\n' "VM (EC2, $STATES)" "$T_EC2" "1" "$W_VM"
printf ' %-38s %12s %8s %10s\n' "  of which EKS nodes (already incl.)" "$T_EKS_NODES" "" "-"
printf ' %-38s %12s %8s %10s\n' "CaaS (Fargate containers + App Runner)" "$CAAS_UNITS" "10" "$W_CAAS"
printf ' %-38s %12s %8s %10s\n' "Serverless (Lambda)" "$T_LAMBDA" "25" "$W_SERVERLESS"
printf ' %-38s %12s %8s %10s\n' "Cloud buckets (S3)" "$T_S3" "10" "$W_BUCKET"
printf ' %-38s %12s %8s %10s\n' "PaaS DB (RDS, Redshift, Aurora SLS v1)" "$PAAS_UNITS" "2" "$W_PAAS"
printf ' %-38s %12s %8s %10s\n' "  of which Aurora instances" "$T_AURORA_INST" "" "-"
printf ' %-38s %12s %8s %10s\n' "DBaaS (DynamoDB, $T_DDB_TABLES tables) GB" "$DDB_GB" "1 TB" "$W_DBAAS"
printf ' %-38s %12s %8s %10s\n' "ECR images (free quota $IMG_FREE)" "$T_ECR_IMAGES" "10" "$W_IMAGES"
echo "----------------------------------------------------------------------------"
printf ' %-38s %12s %8s %10s\n' "TOTAL AWS WORKLOADS" "" "" "$W_TOTAL"
echo "============================================================================"
echo " Not counted by this script: SaaS users, unmanaged Cloud ASM assets,"
echo " EKS pods on Fargate (kubectl required), Amazon Keyspaces and other DBaaS."
echo " Aurora is counted per instance (writer + readers): confirm with Palo Alto."
echo " Per account/region details: $CSV_FILE"

NERR=$(wc -l < "$ERRLOG")
if (( NERR > 0 )); then
  echo ""
  echo " WARNING: $NERR calls failed (the related counts are 0)."
  echo " First 20:"
  head -20 "$ERRLOG" | sed 's/^/   /'
  cp "$ERRLOG" "${CSV_FILE%.csv}-errors.log"
  echo " Full list: ${CSV_FILE%.csv}-errors.log"
fi
