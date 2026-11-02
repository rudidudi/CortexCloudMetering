#!/usr/bin/env bash
# Runs the sizing scripts against mocked CLIs (tests/mock) and checks the expected totals.
# Requirements: python3 with the jmespath module (pip install jmespath).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export PATH="$HERE/mock:$PATH" AWS_DEFAULT_REGION=eu-west-1
unset AWS_SESSION_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

FAIL=0
check() { # check <description> <output> <expected regex>
  if grep -Eq "$3" <<< "$2"; then echo "  OK   $1"; else echo "  FAIL $1 (expected: $3)"; FAIL=1; fi
}
total() { grep -E 'TOTAL .* WORKLOADS' <<< "$1" | grep -Eo '[0-9]+$'; }

cd "$WORK" || exit 1

echo "AWS - single account"
OUT=$(bash "$ROOT/aws/cc-sizing-aws.sh" -f aws1.csv 2>&1)
check "EC2: 6 running instances (not 4 reservations)"      "$OUT" 'VM \(EC2, running\) +6 +1 +6'
check "EKS nodes shown but not added"                       "$OUT" 'of which EKS nodes.* 2 +-$'
check "CaaS: 24 Fargate containers + 1 App Runner = 3 WL"   "$OUT" 'CaaS .* 25 +10 +3$'
check "Lambda across all regions: 60 = 3 WL"                "$OUT" 'Serverless \(Lambda\) +60 +25 +3$'
check "S3: 25 = 3 WL"                                       "$OUT" 'Cloud buckets \(S3\) +25 +10 +3$'
check "PaaS: 4 RDS (Aurora incl.) + 1 SLS + 1 Redshift"     "$OUT" 'PaaS DB .* 6 +2 +3$'
check "DynamoDB 2 TB = 2 WL"                                "$OUT" 'DBaaS .* 2000.0 +1 TB +2$'
check "Images: 300 - free quota 90 = 21 WL"                 "$OUT" 'ECR images \(free quota 90\) +300 +10 +21$'
check "Total 41"                                            "$(total "$OUT")" '^41$'
if grep -q WARNING <<< "$OUT"; then echo "  FAIL unexpected errors"; FAIL=1; else echo "  OK   no errors"; fi

echo "AWS - single account with -s (stopped included)"
OUT=$(bash "$ROOT/aws/cc-sizing-aws.sh" -s -f aws2.csv 2>&1)
check "EC2: 7 instances"                                    "$OUT" 'VM \(EC2, running,stopped\) +7 +1 +7'

echo "AWS - single region (-n)"
OUT=$(bash "$ROOT/aws/cc-sizing-aws.sh" -n eu-south-1 -f aws3.csv 2>&1)
check "Total 7 (2 EC2 + 2 Lambda WL + 3 S3 WL)"             "$(total "$OUT")" '^7$'

echo "AWS - Organization (3 ACTIVE accounts, 1 not accessible)"
OUT=$(bash "$ROOT/aws/cc-sizing-aws.sh" -o -f aws4.csv 2>&1)
check "2 accounts scanned"                                  "$OUT" 'accounts scanned: 2'
check "EC2: 12"                                             "$OUT" 'VM \(EC2, running\) +12 +1 +12'
check "PaaS not cumulative: 12 = 6 WL"                      "$OUT" 'PaaS DB .* 12 +2 +6$'
check "Total 80"                                            "$(total "$OUT")" '^80$'
check "inaccessible account reported"                       "$OUT" 'WARNING: 1 calls failed'
check "CSV generated"                                       "$(head -1 aws4.csv)" '^account,region,'

echo "Azure - all subscriptions"
OUT=$(bash "$ROOT/azure/cc-sizing-azure.sh" -f az1.csv 2>&1)
check "2 enabled subscriptions (disabled one excluded)"     "$OUT" 'subscriptions scanned: 2'
check "VMs: only the 2 running"                             "$OUT" 'VM \(Virtual Machines\) +2 +1 +2$'
check "VMSS Uniform: 7 (Flexible excluded)"                 "$OUT" 'VM Scale Sets .* 7 +1 +7$'
check "AKS nodes shown but not added"                       "$OUT" 'of which AKS nodes.* 4 +-$'
check "Functions: 20 + 1 (unreadable app) = 1 WL"           "$OUT" 'Serverless \(Azure Functions\) +21 +25 +1$'
check "CaaS: 3 ACI + 2 Container Apps = 1 WL"               "$OUT" 'CaaS .* 5 +10 +1$'
check "Storage: 5 = 1 WL"                                   "$OUT" 'Storage accounts\) +5 +10 +1$'
check "PaaS: 3 SQL DB + 1 PG = 2 WL"                        "$OUT" 'PaaS DB .* 4 +2 +2$'
check "Images: 100 within free quota (100) = 0 WL"          "$OUT" 'ACR images \(free quota 100\) +100 +10 +0$'
check "Empty subscription adds no VM"                       "$OUT" 'VM 0 \| VMSS 0'
check "Total 14"                                            "$(total "$OUT")" '^14$'
check "unreadable app reported"                             "$OUT" 'WARNING: 1 calls failed'

echo "Azure - with -s (deallocated included)"
OUT=$(bash "$ROOT/azure/cc-sizing-azure.sh" -s -f az2.csv 2>&1)
check "VMs: 3"                                              "$OUT" 'VM \(Virtual Machines\) +3 +1 +3$'

echo "Azure - single subscription and location filters"
OUT=$(bash "$ROOT/azure/cc-sizing-azure.sh" -u sub-A -n westeurope -f az3.csv 2>&1)
check "Total 14"                                            "$(total "$OUT")" '^14$'
OUT=$(bash "$ROOT/azure/cc-sizing-azure.sh" -n northeurope -f az4.csv 2>&1)
check "No resources in northeurope: total 0"                "$(total "$OUT")" '^0$'

echo
if (( FAIL )); then echo "RESULT: some tests FAILED"; exit 1; else echo "RESULT: all tests passed"; fi
