# Cortex Cloud Metering – workload sizing scripts

Scripts to estimate **Cortex Cloud workloads** (Palo Alto Networks) for AWS, Azure and GCP,
following the rules of the *Cortex Cloud Metering Guide*.

They are based on the official
[PaloAltoNetworks/cc-workload-sizing](https://github.com/PaloAltoNetworks/cc-workload-sizing) scripts
(commit `71b5aa0`, 2026-05-13).

## Repository layout

**Status: work in progress.**

| Folder | Script | State |
|---|---|---|
| `aws/` | `cc-workload-sizing-aws.sh` | Official script with fixes (see [AWS: changes from the official script](#aws-changes-from-the-official-script)) |
| `azure/` | `cc-workload-sizing-azure.sh` | Official script, unchanged |
| `gcp/` | `cc-workload-sizing-gcp.sh` | Official script, unchanged |

## Conversion rules

From the Cortex Cloud Metering Guide:

| Resource type | 1 workload = |
|---|---|
| VMs, with or without containers | 1 VM |
| CaaS (managed containers) | 10 containers |
| Serverless functions | 25 functions |
| Cloud buckets | 10 buckets |
| PaaS databases | 2 databases |
| DBaaS | 1 TB stored |
| SaaS users | 10 users |
| Cloud ASM unmanaged assets | 4 assets |
| Container images | 10 free scans per deployed VM or CaaS workload, then 10 scans = 1 workload |

Logs are not workloads: 1 GB of logs is included every 50 workloads.

## Requirements

| Cloud | Tools | Permissions |
|---|---|---|
| AWS | AWS CLI v2, `jq` | Read-only access in every account. With `-o`, also `organizations:ListAccounts` and a role the script can assume in each member account |
| Azure | Azure CLI, `jq` | `Reader` on the subscriptions |
| GCP | `gcloud`, `jq` | Cloud Asset Inventory API enabled, `roles/cloudasset.viewer` |

The easiest way to run them is from **AWS CloudShell**, **Azure Cloud Shell** or **Google Cloud Shell**,
where the CLI and `jq` are already installed.

## Usage

### AWS

```bash
curl -sO https://raw.githubusercontent.com/rudidudi/CortexCloudMetering/main/aws/cc-workload-sizing-aws.sh
chmod +x cc-workload-sizing-aws.sh
./cc-workload-sizing-aws.sh
```

| Option | Description |
|---|---|
| `-h` | Show the help |
| `-n <region>` | Scan a single region |
| `-o` | Organization mode: scan every `ACTIVE` account (run it from the management account) |
| `-r <role>` | Role to assume in each account with `-o` (default `OrganizationAccountAccessRole`) |
| `-s` | Also count stopped EC2 instances |

### Azure

```bash
curl -sO https://raw.githubusercontent.com/rudidudi/CortexCloudMetering/main/azure/cc-workload-sizing-azure.sh
chmod +x cc-workload-sizing-azure.sh
./cc-workload-sizing-azure.sh
```

| Option | Description |
|---|---|
| `-h` | Show the help |
| `-n <location>` | Scan a single location |
| `-s` | Also count stopped (deallocated) VMs. Note: the official script already counts them by default |

### GCP

```bash
curl -sO https://raw.githubusercontent.com/rudidudi/CortexCloudMetering/main/gcp/cc-workload-sizing-gcp.sh
chmod +x cc-workload-sizing-gcp.sh
./cc-workload-sizing-gcp.sh
```

| Option | Description |
|---|---|
| `-h` | Show the help |
| `-o <id>` | Scan a single organization (default: every organization you can access) |
| `-l <location>` | Filter resources by location, e.g. `us-central1` |

## AWS: changes from the official script

- **All regions:** every regional service (EC2, Lambda, ECS, App Runner, ECR, EFS, Aurora, RDS, DynamoDB, Redshift)
  is listed in every region enabled in each account. The official script read everything except EC2
  only in the CLI's default region. Regions where a service is not offered are skipped, other errors are printed
  as warnings, and `-n` now also filters S3 buckets.
- **EC2:** counts instances, not reservations.
- **Stopped instances:** counted only with `-s` (the official script always counted them).
- **EKS:** worker nodes are counted once, as EC2 instances. The official script added them again on top
  (twice more for a cluster with one node group).
- **Aurora:** counts `aurora-mysql` and `aurora-postgresql` clusters, not only the legacy `aurora` engine.
- **RDS:** counts every engine (Oracle, SQL Server and Db2 included), except Aurora, DocumentDB and Neptune.
- **Fargate:** counts services that run on Fargate through a capacity provider strategy (`FARGATE`, `FARGATE_SPOT`).
- **Lambda:** one call per region instead of one call per function.
- **Container images:** the per-account total uses the right variable, and negative values are clamped to 0.
- **PaaS databases:** converted to workloads once, on the total of all accounts.
- **`-d`:** removed; it was accepted but did nothing.

## AWS: known open issues

- **Container images:** the image count uses `wc -l` (lines, not images), the free quota is subtracted per repository,
  CaaS workloads are left out of the quota, and the excess is not divided by 10.
- **CaaS:** counts Fargate services, not containers. Standalone ECS tasks and EKS pods on Fargate are not counted,
  and each App Runner service counts as 1.
- **Rounding:** Serverless, CaaS and S3 are still rounded up in each account instead of once on the total.
- **Organization mode:** the script also tries to assume the role in the management account, where it usually
  does not exist, so that account is skipped.
- **Errors:** a failed S3 or account-level call stops the whole run.
- **Not counted:** Lightsail instances, DocumentDB, Neptune, ElastiCache, OpenSearch, SaaS users,
  Cloud ASM unmanaged assets, DBaaS TB stored.
- **To confirm with Palo Alto Networks:** DynamoDB and Redshift are counted as PaaS (2 = 1 workload), not as DBaaS
  per TB; Aurora is counted per cluster, not per instance.
- `-c` is accepted but does nothing.

## Disclaimer

Unofficial tool, provided for preliminary estimates. The reference count for licensing purposes
is the one agreed with Palo Alto Networks.
