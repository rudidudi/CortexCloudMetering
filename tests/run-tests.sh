#!/usr/bin/env bash
# Esegue gli script di sizing contro CLI simulate (tests/mock) e verifica i totali attesi.
# Requisiti: python3 con il modulo jmespath (pip install jmespath).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export PATH="$HERE/mock:$PATH" AWS_DEFAULT_REGION=eu-west-1
unset AWS_SESSION_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

FAIL=0
check() { # check <descrizione> <output> <regex atteso>
  if grep -Eq "$3" <<< "$2"; then echo "  OK   $1"; else echo "  FAIL $1 (atteso: $3)"; FAIL=1; fi
}
total() { grep -E 'TOTALE WORKLOAD' <<< "$1" | grep -Eo '[0-9]+$'; }

cd "$WORK" || exit 1

echo "AWS - singolo account"
OUT=$(bash "$ROOT/aws/cc-sizing-aws.sh" -f aws1.csv 2>&1)
check "EC2: 6 istanze running (non 4 reservation)"        "$OUT" 'VM \(EC2, running\) +6 +1 +6'
check "nodi EKS mostrati ma non sommati"                    "$OUT" 'di cui nodi EKS.* 2 +-$'
check "CaaS: 24 container Fargate + 1 App Runner = 3 WL"    "$OUT" 'CaaS .* 25 +10 +3$'
check "Lambda su tutte le regioni: 60 = 3 WL"               "$OUT" 'Serverless \(Lambda\) +60 +25 +3$'
check "S3: 25 = 3 WL"                                       "$OUT" 'Cloud bucket \(S3\) +25 +10 +3$'
check "PaaS: 4 RDS (Aurora incluso) + 1 SLS + 1 Redshift"   "$OUT" 'DB PaaS .* 6 +2 +3$'
check "DynamoDB 2 TB = 2 WL"                                "$OUT" 'DBaaS .* 2000.0 +1 TB +2$'
check "Immagini: 300 - quota 90 = 21 WL"                    "$OUT" 'Immagini ECR \(quota gratuita 90\) +300 +10 +21$'
check "Totale 41"                                           "$(total "$OUT")" '^41$'
if grep -q ATTENZIONE <<< "$OUT"; then echo "  FAIL errori inattesi"; FAIL=1; else echo "  OK   nessun errore"; fi

echo "AWS - singolo account con -s (anche stopped)"
OUT=$(bash "$ROOT/aws/cc-sizing-aws.sh" -s -f aws2.csv 2>&1)
check "EC2: 7 istanze"                                      "$OUT" 'VM \(EC2, running,stopped\) +7 +1 +7'

echo "AWS - Organization (3 account ACTIVE, 1 inaccessibile)"
OUT=$(bash "$ROOT/aws/cc-sizing-aws.sh" -o -f aws3.csv 2>&1)
check "2 account scansionati"                               "$OUT" 'account scansionati: 2'
check "EC2: 12"                                             "$OUT" 'VM \(EC2, running\) +12 +1 +12'
check "PaaS non cumulativo: 12 = 6 WL"                      "$OUT" 'DB PaaS .* 12 +2 +6$'
check "Totale 80"                                           "$(total "$OUT")" '^80$'
check "account inaccessibile segnalato"                     "$OUT" 'ATTENZIONE: 1 chiamate'
check "CSV generato"                                        "$(wc -l < aws3.csv)" '^[0-9]+$'

echo "Azure - tutte le subscription"
OUT=$(bash "$ROOT/azure/cc-sizing-azure.sh" -f az1.csv 2>&1)
check "2 subscription abilitate (la disabilitata e' esclusa)" "$OUT" 'subscription scansionate: 2'
check "VM: solo 2 running"                                  "$OUT" 'VM \(Virtual Machines\) +2 +1 +2$'
check "VMSS Uniform: 7 (Flexible escluso)"                  "$OUT" 'VM Scale Set .* 7 +1 +7$'
check "nodi AKS mostrati ma non sommati"                    "$OUT" 'di cui nodi AKS.* 4 +-$'
check "Functions: 20 + 1 (app illeggibile) = 1 WL"          "$OUT" 'Serverless \(Azure Functions\) +21 +25 +1$'
check "CaaS: 3 ACI + 2 Container Apps = 1 WL"               "$OUT" 'CaaS .* 5 +10 +1$'
check "Storage: 5 = 1 WL"                                   "$OUT" 'Storage account\) +5 +10 +1$'
check "PaaS: 3 SQL DB + 1 PG = 2 WL"                        "$OUT" 'DB PaaS .* 4 +2 +2$'
check "Immagini: 100 dentro la quota (100) = 0 WL"          "$OUT" 'Immagini ACR \(quota gratuita 100\) +100 +10 +0$'
check "Subscription vuota non aggiunge VM"                  "$OUT" 'VM 0 \| VMSS 0'
check "Totale 14"                                           "$(total "$OUT")" '^14$'
check "app non leggibile segnalata"                         "$OUT" 'ATTENZIONE: 1 chiamate'

echo "Azure - con -s (anche deallocate)"
OUT=$(bash "$ROOT/azure/cc-sizing-azure.sh" -s -f az2.csv 2>&1)
check "VM: 3"                                               "$OUT" 'VM \(Virtual Machines\) +3 +1 +3$'

echo
if (( FAIL )); then echo "RISULTATO: alcuni test sono FALLITI"; exit 1; else echo "RISULTATO: tutti i test superati"; fi
