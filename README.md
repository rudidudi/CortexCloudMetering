# Cortex Cloud Metering – AWS and Azure sizing scripts

Scripts to estimate **Cortex Cloud workloads** (Palo Alto Networks) for an AWS or Azure environment,
applying the rules of the *Cortex Cloud Metering Guide*.

They started as a fixed version of the official
[PaloAltoNetworks/cc-workload-sizing](https://github.com/PaloAltoNetworks/cc-workload-sizing) scripts,
which contain several counting errors (see [Differences from the official scripts](#differences-from-the-official-scripts)).

## Repository layout

**Status: work in progress.** Everything in this repository is still being worked on.

Each cloud provider has its own folder (`aws/`, `azure/`, `gcp/`) with two subfolders:

| Folder | Content |
|---|---|
| `<provider>/script/` | The new sizing script, rewritten to follow the Cortex Cloud Metering Guide |
| `<provider>/original/` | The official script from [PaloAltoNetworks/cc-workload-sizing](https://github.com/PaloAltoNetworks/cc-workload-sizing) (commit `71b5aa0`, 2026-05-13), with the fixes applied one at a time |

Today `original/` still holds the official scripts unchanged, and the new AWS and Azure scripts are still at
`aws/cc-sizing-aws.sh` and `azure/cc-sizing-azure.sh`: they will move to `aws/script/` and `azure/script/`.
There is no new GCP script yet.

## Conversion rules

| Resource type | Resources per workload |
|---|---|
| VM (with or without containers, Kubernetes nodes included) | 1 |
| CaaS – managed containers (Fargate, App Runner, ACI, Container Apps) | 10 |
| Serverless functions (Lambda, Azure Functions) | 25 |
| Cloud buckets (S3, Storage accounts) | 10 |
| PaaS databases (RDS, Aurora, Redshift, Azure SQL, PostgreSQL/MySQL flexible) | 2 |
| DBaaS (DynamoDB) | 1 TB stored |
| Registry images | 10 scans beyond the free quota (10 per VM/CaaS workload) |

Rounding up is applied **to the total of each category**, not per account or subscription.

## Requirements

- **AWS:** AWS CLI v2. `ReadOnlyAccess` (or `SecurityAudit` + `ViewOnlyAccess`) in every account;
  in Organization mode also `organizations:ListAccounts` and `sts:AssumeRole`.
- **Azure:** Azure CLI. `Reader` role on the subscriptions (or on the Management Group). Counting ACR images
  also requires access to the registry (`AcrPull` or `Reader`) and network reachability.
- **No `jq` needed**: every filter uses the CLI's built-in `--query` (JMESPath).

The easiest way to run them is from **AWS CloudShell** or **Azure Cloud Shell**, where the CLIs are ready to use.

## Usage

### AWS

```bash
chmod +x aws/cc-sizing-aws.sh

./aws/cc-sizing-aws.sh                   # current account, all enabled regions
./aws/cc-sizing-aws.sh -o                # every account in the Organization
./aws/cc-sizing-aws.sh -o -r MyRole      # Organization with a different cross-account role
./aws/cc-sizing-aws.sh -n eu-west-1      # single region
./aws/cc-sizing-aws.sh -s                # also include stopped EC2 instances
```

| Option | Description |
|---|---|
| `-o` | Organization mode: scans every `ACTIVE` account (run it from the management account) |
| `-r <role>` | Role to assume in member accounts (default `OrganizationAccountAccessRole`) |
| `-n <region>` | Single region |
| `-s` | Include `stopped` EC2 instances |
| `-f <file.csv>` | Name of the detailed CSV file |

### Azure

```bash
chmod +x azure/cc-sizing-azure.sh

./azure/cc-sizing-azure.sh                   # every enabled subscription
./azure/cc-sizing-azure.sh -u <sub-id>       # single subscription
./azure/cc-sizing-azure.sh -n westeurope     # single location
./azure/cc-sizing-azure.sh -s                # also include deallocated VMs
```

| Option | Description |
|---|---|
| `-u <id\|name>` | Single subscription |
| `-n <location>` | Single location |
| `-s` | Include deallocated VMs |
| `-f <file.csv>` | Name of the detailed CSV file |

## Output

Each script prints a summary table with resources, ratio and workloads per category, and creates:

- a **CSV** file with per account/region (AWS) or per subscription (Azure) details, ready for Excel;
- an **`-errors.log`** file if any call failed (missing permissions, role not assumable,
  unreachable registry…). The summary reports it, and the affected counts are 0.

## What is counted

### AWS

| Category | What is counted |
|---|---|
| VM | `running` EC2 instances in every region (**instances**, not reservations). EKS/ECS nodes on EC2 are already included and shown separately for information only |
| CaaS | Containers in running ECS **Fargate** tasks + App Runner services |
| Serverless | Lambda functions in every region |
| Buckets | S3 buckets |
| PaaS DB | Every RDS instance (MySQL, PostgreSQL, MariaDB, Oracle, SQL Server, **Aurora**, DocumentDB, Neptune), Aurora Serverless v1 clusters, Redshift clusters |
| DBaaS | DynamoDB tables, converted into TB stored |
| Images | Images (manifests) in ECR repositories, net of the free quota |

### Azure

| Category | What is counted |
|---|---|
| VM | `running` VMs + *Uniform* VM Scale Set instances. AKS nodes are VMSS instances: counted once and shown separately |
| CaaS | Containers in ACI container groups + containers defined in Container Apps |
| Serverless | Individual functions inside each Function App (an unreadable app counts as 1 and is reported) |
| Buckets | Storage accounts |
| PaaS DB | Azure SQL databases (excluding `master`), SQL Managed Instances, PostgreSQL and MySQL flexible servers |
| Images | Manifests in ACR repositories, net of the free quota |

## Known limitations – complete manually or confirm with Palo Alto

- Not counted: **SaaS users**, unmanaged **Cloud ASM assets**, EKS pods on Fargate and pods on AKS virtual nodes
  (`kubectl` required), Amazon Keyspaces, **Cosmos DB** (DBaaS per TB: the script reports the number of accounts).
- **Aurora** is counted per instance (writer + readers): check whether Palo Alto counts it per cluster.
- **Azure SQL** is counted per database, not per logical server (the number of servers is reported anyway).
- Azure **storage accounts** are used as the bucket equivalent.
- The scripts take a snapshot at run time: with autoscaling, run them at different times
  or compare with the 30-day average.

## Differences from the official scripts

Issues found in `PaloAltoNetworks/cc-workload-sizing` (version of 2026-05-13) and fixed here:

**AWS**
- EC2 counted *reservations* instead of instances (undercount).
- Stopped instances were always counted.
- EKS nodes were added a second time on top of EC2, with a wrong cumulative formula.
- Lambda, ECS, ECR, RDS, DynamoDB, Redshift and EKS were read only in the default region.
- Fargate always 0 (compared against `"Fargate"` instead of `"FARGATE"`).
- Container images always 0 (undefined variable).
- Aurora never counted (filter on the legacy `aurora` engine only).
- DynamoDB counted as PaaS per table instead of DBaaS per TB.
- In Organization mode PaaS was summed cumulatively and the Lambda counter was never reset.
- API call errors were silently ignored.

**Azure**
- Every ACR image counted as 1 workload, with no free quota and no division by 10.
- A subscription with no VMs still counted 1 VM.
- Deallocated VMs were always counted; non-AKS VM Scale Sets were ignored.
- Function Apps were counted instead of functions, and container groups instead of containers.
- Rounding per subscription (overcount with many small subscriptions).
- Used the retired PostgreSQL/MySQL/MariaDB *Single Server* commands.

## Tests

The tests run the scripts against mocked CLIs (`tests/mock/`) whose expected result is known:

```bash
pip install jmespath
./tests/run-tests.sh
```

## Disclaimer

Unofficial tool, provided for preliminary estimates. The reference count for licensing purposes
is the one agreed with Palo Alto Networks.
