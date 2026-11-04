#!/bin/bash

# Based on cc-workload-sizing-aws.sh from PaloAltoNetworks/cc-workload-sizing (commit 71b5aa0), with fixes.
# Every regional service (EC2, Lambda, ECS, App Runner, ECR, EFS, Aurora, RDS, DynamoDB, Redshift) is listed
# in every region enabled in each account. See the README for the full list of changes and open issues.

# Check for jq dependency
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq to run this script."
    echo "(e.g., 'sudo apt-get install jq' or 'sudo yum install jq' or 'brew install jq')"
    exit 1
fi
# Function to handle errors
function check_error {
    local exit_code=$1
    local message=$2
    if [ $exit_code -ne 0 ]; then
        echo "Error: $message (Exit Code: $exit_code)"
        # Optionally unset credentials if in org mode before exiting
        if [ "$ORG_MODE" == true ] && [ -n "$AWS_SESSION_TOKEN" ]; then
            unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
        fi
        exit $exit_code
    fi
}

# Run an AWS CLI listing in every region to scan (scan_regions) and print the IDs it returns, one per line.
# The regions with results are reported on stderr, so $(...) captures only the IDs.
# A region where the service is not offered is skipped; any other failure is reported as a warning.
function list_in_regions {
    local label=$1; shift
    local r out n err
    err=$(mktemp)
    for r in $scan_regions; do
        if ! out=$("$@" --region "$r" --output text 2>"$err"); then
            if ! grep -q "Could not connect to the endpoint" "$err"; then
                echo "    Warning: could not list $label in $r: $(grep -m 1 . "$err")" >&2
            fi
            continue
        fi
        n=$(echo "$out" | wc -w)
        if (( n > 0 )); then
            echo "    Region $r: $n $label" >&2
            echo "$out" | tr -s '[:space:]' '\n'
        fi
    done
    rm -f "$err"
}

function printHelp {
    echo ""
    echo "NOTES:"
    echo "* Requires AWS CLI v2 to execute"
    echo "* Requires JQ utility to be installed (TODO: Install JQ from script; exists in AWS)"
    echo "* Validated to run successfully from within CSP console CLIs"
    echo ""
    echo "Available flags:"
    echo " -h          Display the help info"
    echo " -n <region> Single region to scan"
    echo " -o          Organization mode"
    echo "             This option will fetch all sub-accounts associated with an organization"
    echo "             and assume the default (or specified) cross account role in order to iterate through and"
    echo "             scan resources in each sub-account. This is typically run from the admin user in"
    echo "             the master account."
    echo " -r <role>   Specify a non default role to assume in combination with organization mode"
    echo " -s          Include stopped instances in addition to running ones"
    echo ""
    exit 1
}

echo "$(tput bold)$(tput setaf 2)";
echo "   ___           _                ___ _                 _ ";
echo "  / __\___  _ __| |_ _____  __   / __\ | ___  _   _  __| |";
echo " / /  / _ \| '__| __/ _ \ \/ /  / /  | |/ _ \| | | |/ _\` |";
echo "/ /__| (_) | |  | ||  __/>  <  / /___| | (_) | |_| | (_| |";
echo "\____/\___/|_|   \__\___/_/\_\ \____/|_|\___/ \__,_|\__,_|";
echo "                                                          ";
echo "                                                          ";
echo "$(tput sgr0)";

# Ensure AWS CLI is configured
aws sts get-caller-identity > /dev/null 2>&1
check_error $? "AWS CLI not configured or credentials invalid. Please run 'aws configure'."

# Initialize options
ORG_MODE=false
ROLE="OrganizationAccountAccessRole"
REGION=""
STATE="running"

# Get options
while getopts ":chn:or:s" opt; do
  case ${opt} in
    c) SSM_MODE=true ;;
    h) printHelp ;;
    n) REGION="$OPTARG" ;;
    o) ORG_MODE=true ;;
    r) ROLE="$OPTARG" ;;
    s) STATE="running,stopped" ;;
    *) echo "Invalid option: -${OPTARG}" && printHelp exit ;;
 esac
done
shift $((OPTIND-1))

# Get active regions
# Get enabled regions for the current account context
echo "Fetching enabled regions for the account..."
activeRegions=$(aws account list-regions --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT --query "Regions[].RegionName" --output text)
check_error $? "Failed to list enabled AWS regions. Ensure 'account:ListRegions' permission is granted."

if [ -z "$activeRegions" ]; then
    echo "Error: Could not retrieve list of enabled regions."
    exit 1
fi
echo "Enabled regions found: $activeRegions"

# Validate region flag
if [[ "${REGION}" ]]; then
    # Use grep -w for whole word match to avoid partial matches (e.g., "us-east" matching "us-east-1")
    if echo "$activeRegions" | grep -qw "$REGION";
        then echo "Requested region is valid";
    else echo "Invalid region requested: $REGION";
    exit 1
    fi 
fi

if [ "$ORG_MODE" == true ]; then
  echo "Organization mode active"
  echo "Role to assume: $ROLE"
fi

# Initialize counters
total_ec2_instances=0
total_s3_buckets=0
total_functions=0
total_efs=0
total_aurora=0
total_rds=0
total_dynamodb=0
total_redshift=0
total_ec2_db=0
ec2_db_count=0
total_paas_workloads=0
caas_workloads=0
total_caas_workloads=0
container_image_workloads=0
total_container_image_workloads=0
serverless_workloads=0
total_serverless_workloads=0
s3_workloads=0
total_s3_workloads=0

# Function to count resources in a single account
count_resources() {
    local account_id=$1

    if [ "$ORG_MODE" == true ]; then
        # Assume role in the account (replace "OrganizationAccountAccessRole" with your role name if different)
        # Capture stderr to prevent it from cluttering the output if it fails
        creds=$(aws sts assume-role --role-arn "arn:aws:iam::$account_id:role/$ROLE" \
            --role-session-name "OrgSession" --query "Credentials" --output json 2> /dev/null)
        local assume_role_exit_code=$?

        if [ $assume_role_exit_code -ne 0 ]; then
            echo "  Warning: Unable to assume role '$ROLE' in account $account_id (Exit Code: $assume_role_exit_code). Skipping account..."
            # No need to unset creds as they weren't successfully set
            return
        fi

        # Double check creds are not empty even if command succeeded
        if [ -z "$creds" ]; then
             echo "  Warning: Assumed role in account $account_id but credentials seem empty. Skipping account..."
             return
        fi

        # Export temporary credentials
        export AWS_ACCESS_KEY_ID=$(echo $creds | jq -r ".AccessKeyId")
        export AWS_SECRET_ACCESS_KEY=$(echo $creds | jq -r ".SecretAccessKey")
        export AWS_SESSION_TOKEN=$(echo $creds | jq -r ".SessionToken")
    fi

    echo ""
    echo "Counting Cloud Security resources in account: $account_id"

    # Regions to scan in this account: the one given with -n, or every region enabled in this account.
    # Every regional service below is listed in each of these regions, not only in the CLI's default region.
    if [[ "${REGION}" ]]; then
        scan_regions="$REGION"
    elif ! scan_regions=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text 2>/dev/null); then
        echo "  Warning: could not list the regions enabled in account $account_id, scanning the regions found at start instead."
        scan_regions="$activeRegions"
    fi
    echo "  Regions to scan: $(echo $scan_regions | wc -w)"

    # Count EC2 instances
    echo "  Counting EC2 instances..."
    ec2_count=$(list_in_regions "EC2 instances" aws ec2 describe-instances --filters "Name=instance-state-name,Values=$STATE" --query "Reservations[].Instances[].InstanceId" | wc -l)
    echo "  $(tput bold)$(tput setaf 2)VM Workloads: $ec2_count$(tput sgr0)"
    total_ec2_instances=$((total_ec2_instances + ec2_count))
    total_ec2_workloads=$total_ec2_instances

    # EKS worker nodes are EC2 instances, so they are already included in the VM count above

    # Count Serverless Functions
    echo ""
    echo "  Counting serverless functions in AWS..."

    # Count all Lambda functions with one call per region. Active and inactive functions are both counted,
    # so there is no need to look up each function's state.
    total_functions=$(list_in_regions "Lambda functions" aws lambda list-functions --query 'Functions[].FunctionArn' | wc -l)

    if (( total_functions == 0 )); then
        echo "    No serverless functions found in your AWS account."
    else
        echo "    Total Serverless Functions: $total_functions"
    fi

    serverless_workloads=$(( (total_functions +25-1)/25 ))
    if (( $total_functions == 0 )); then 
        serverless_workloads=0
    fi
    total_serverless_workloads=$((total_serverless_workloads + serverless_workloads))
    echo "  $(tput bold)$(tput setaf 2)Serverless Workloads: $serverless_workloads$(tput sgr0)"

    # Count CaaS
    echo ""
    echo "  Counting managed container resources in AWS..."

    # Initialize counters
    ecs_fargate_services=0
    apprunner_services=0
    total_managed_containers=0

    # List the ECS clusters in every region to scan
    # We'll then iterate through each cluster to find Fargate services.
    ecs_clusters=$(list_in_regions "ECS clusters" aws ecs list-clusters --query 'clusterArns[]')

    if [ -z "$ecs_clusters" ]; then
        echo "    No ECS clusters found."
        else
            for cluster_arn in $ecs_clusters; do
                cluster_name=$(echo "$cluster_arn" | awk -F'/' '{print $NF}')
                # The cluster ARN (arn:aws:ecs:<region>:<account>:cluster/<name>) carries its region
                cluster_region=$(echo "$cluster_arn" | cut -d: -f4)
                echo "    Checking cluster: $cluster_name ($cluster_region)"

                # List services within the cluster
                # We need to describe each service to check its launch type (Fargate vs. EC2)
                service_arns=$(aws ecs list-services --region "$cluster_region" --cluster "$cluster_arn" --query 'serviceArns[]' --output text)

                if [ -z "$service_arns" ]; then
                    echo "      No services found in this cluster."
                else
                for service_arn in $service_arns; do
                    # Get the launch type and the capacity providers: services that use a capacity provider
                    # strategy have no launch type, so Fargate shows up as the FARGATE or FARGATE_SPOT provider
                    service_details=$(aws ecs describe-services --region "$cluster_region" --cluster "$cluster_arn" --services "$service_arn" --query 'services[0].[launchType, capacityProviderStrategy[].capacityProvider][]' --output text)

                    if echo "$service_details" | grep -Eqw 'FARGATE|FARGATE_SPOT'; then
                     ecs_fargate_services=$((ecs_fargate_services + 1))
                      service_name=$(echo "$service_arn" | awk -F'/' '{print $NF}')
                     echo "    Found Fargate Service: $service_name"
                    fi
                done
                fi
            done
        fi

        # List the App Runner services in every region to scan (regions without App Runner are skipped)
        apprunner_service_arns=$(list_in_regions "App Runner services" aws apprunner list-services --query 'ServiceSummaryList[].ServiceArn')

        if [ -z "$apprunner_service_arns" ]; then
        echo "    No AWS App Runner services found."
        else
        for service_arn in $apprunner_service_arns; do
            apprunner_services=$((apprunner_services + 1))
            service_name=$(echo "$service_arn" | awk -F'/' '{print $NF}')
            echo "    Found App Runner Service: $service_name"
        done
        fi

        total_managed_containers=$((ecs_fargate_services + apprunner_services))
        caas_workloads=$[(total_managed_containers+10-1)/10]
        if (( total_managed_containers=0 )); then 
            caas_workloads=0
        fi
        total_caas_workloads=$((total_caas_workloads + caas_workloads))
        echo "  $(tput bold)$(tput setaf 2)CaaS Workloads: $caas_workloads$(tput sgr0)"
        echo ""

        # Count Container Images in Registries
        echo "  Counting container images in all registries..."

        # Initialize a counter for the total number of images across all repositories
        total_images_across_all_registries=0

        # List the ECR repositories in every region to scan, one ARN per line
        # The ARN (arn:aws:ecr:<region>:<account>:repository/<name>) carries the region and the name
        repository_arns=$(list_in_regions "ECR repositories" aws ecr describe-repositories --query 'repositories[].repositoryArn')

        # Check if any repositories were found
        if [ -z "$repository_arns" ]; then
        echo "    No ECR repositories found in your AWS account."
        else

            # Loop through each repository
            for repo_arn in $repository_arns; do
            repo_region=$(echo "$repo_arn" | cut -d: -f4)
            # The name can contain slashes (e.g. team/app), so keep everything after "repository/"
            repo_name=${repo_arn#*:repository/}

            # Count images in the current repository
            # We use describe-images to get a list of image digests (unique identifiers for images).
            # We then use wc -l to count the number of lines, which corresponds to the number of images.
            # The || true part prevents the script from exiting if a repository has no images and describe-images returns an empty list.
            image_count=$(aws ecr describe-images --region "$repo_region" --repository-name "$repo_name" --query 'imageDetails[].imageDigest' --output text | wc -l)

            # Add the current repository's image count to the total
            total_images_across_all_registries=$((total_images_across_all_registries + image_count))
            container_image_workload=$[(image_count-(ec2_count*10))]
            container_image_workload=$(( container_image_workload < 0 ? 0 : container_image_workload ))
            total_container_image_workloads=$((total_container_image_workloads + container_image_workload))
                done

            echo "  Total ECR Repositories Found: $(echo "$repository_arns" | wc -l)"
            echo "  Total Images Across All Registries: $total_images_across_all_registries"
        fi
        echo "  $(tput bold)$(tput setaf 2)Container Image Workloads: $total_container_image_workloads$(tput sgr0)"
        echo ""

        # Count S3 buckets
        echo "  Counting up bucket workloads..."
        # list-buckets is global: it returns the buckets of every region from any endpoint.
        # With -n, --bucket-region keeps only the buckets in the requested region.
        if [[ "${REGION}" ]]; then
            s3_count=$(aws s3api list-buckets --bucket-region "$REGION" --query "Buckets[*].Name" --output text | wc -w)
            check_error $? "Failed to list S3 buckets in region $REGION for account $account_id."
        else
            s3_count=$(aws s3api list-buckets --query "Buckets[*].Name" --output text | wc -w)
            check_error $? "Failed to list S3 buckets (all regions) for account $account_id."
        fi   
        echo "    S3 buckets: $s3_count"
        total_s3_buckets=$((total_s3_buckets + s3_count))
        s3_workloads=$[(total_s3_buckets+10-1)/10]
        if (( total_s3_buckets=0 )); then
            s3_workloads=0
        fi
        total_s3_workloads=$((total_s3_workloads + s3_workloads))
        echo "  $(tput bold)$(tput setaf 2)S3 workloads: $s3_workloads$(tput sgr0)"
        echo ""

        echo "  Counting up PaaS workloads..."
        # Count EFS file systems
        efs_count=$(list_in_regions "EFS file systems" aws efs describe-file-systems --query "FileSystems[*].FileSystemId" | wc -l)
        echo "    EFS file systems: $efs_count"
        total_efs=$((total_efs + efs_count))

        # Count Aurora clusters
        aurora_count=$(list_in_regions "Aurora clusters" aws rds describe-db-clusters --query "DBClusters[?starts_with(Engine, 'aurora')].DBClusterIdentifier" | wc -l)
        echo "    Aurora clusters: $aurora_count"
        total_aurora=$((total_aurora + aurora_count))

        # Count RDS instances of every engine except Aurora (counted per cluster above), DocumentDB and Neptune
        rds_count=$(list_in_regions "RDS instances" aws rds describe-db-instances --query "DBInstances[?!starts_with(Engine, 'aurora') && Engine!='docdb' && Engine!='neptune'].DBInstanceIdentifier" | wc -l)
        echo "    RDS instances (MySQL, MariaDB, PostgreSQL, Oracle, SQL Server, Db2): $rds_count"
        total_rds=$((total_rds + rds_count))

        # Count DynamoDB tables
        dynamodb_count=$(list_in_regions "DynamoDB tables" aws dynamodb list-tables --query "TableNames" | wc -l)
        echo "    DynamoDB tables: $dynamodb_count"
        total_dynamodb=$((total_dynamodb + dynamodb_count))

        # Count Redshift clusters
        redshift_count=$(list_in_regions "Redshift clusters" aws redshift describe-clusters --query "Clusters[*].ClusterIdentifier" | wc -l)
        echo "    Redshift clusters: $redshift_count"
        total_redshift=$((total_redshift + redshift_count))

        # The total_* counters add up databases across all accounts; they are converted to workloads once, after the account loop
        echo "  $(tput bold)$(tput setaf 2)PaaS databases: $((rds_count + aurora_count + dynamodb_count + redshift_count))$(tput sgr0)"

    # Unset temporary credentials only if they were successfully set
    if [ "$ORG_MODE" == true ] && [ -n "$AWS_SESSION_TOKEN" ]; then
        # Unset temporary credentials
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    fi
}

# Main logic
if [ "$ORG_MODE" == true ]; then
    # Get the list of all accounts in the AWS Organization
    # Filter for ACTIVE accounts only
    accounts=$(aws organizations list-accounts --query "Accounts[?Status=='ACTIVE'].Id" --output text)
    check_error $? "Failed to list accounts in the organization. Ensure you have 'organizations:ListAccounts' permission."

    if [ -z "$accounts" ]; then
        echo "No accounts found in the organization."
        exit 0
    fi

    # Loop through each account in the organization
    for account_id in $accounts; do
        count_resources "$account_id"
    done
else
    # Run for the standalone account
    current_account=$(aws sts get-caller-identity --query "Account" --output text)
    check_error $? "Failed to get caller identity for the current account."
    count_resources "$current_account"
fi

# PaaS: 2 databases = 1 workload, rounded up once on the databases of all accounts
total_paas_workloads=$(( (total_rds + total_aurora + total_dynamodb + total_redshift + 1) / 2 ))

    echo ""
    echo "  -- AWS WORKLOAD COUNTS --"
    echo "     VM workloads: $total_ec2_instances"
    echo "     Serverless workloads: $total_serverless_workloads"
    echo "     S3 workloads: $total_s3_workloads"
    echo "     CaaS workloads: $total_caas_workloads"
    echo "     Container Image workloads: $total_container_image_workloads"
    echo "     PaaS workloads: $total_paas_workloads"  
    echo ""
    echo "$(tput bold)$(tput setaf 2)** SUM TOTAL AWS WORKLOADS: $((total_ec2_instances+total_serverless_workloads+total_s3_workloads+total_caas_workloads+total_container_image_workloads+total_paas_workloads)) **$(tput sgr0)"
