#!/bin/bash

# No need to source config.sh here as it's sourced in setup-aws.sh

# Error handling function
handle_error() {
    echo -e "${RED}Error: $1${NC}"
    echo -e "${YELLOW}Stack trace:${NC}"
    local frame=0
    while caller $frame; do
        ((frame++));
    done
    exit 1
}

# Check AWS CLI installation
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        handle_error "AWS CLI is not installed. Please install it first."
    fi

    # Check AWS CLI version
    AWS_CLI_VERSION=$(aws --version 2>&1 | cut -d' ' -f1 | cut -d'/' -f2)
    if [[ "$AWS_CLI_VERSION" < "2.0.0" ]]; then
        handle_error "AWS CLI version 2.0.0 or higher is required. Current version: $AWS_CLI_VERSION"
    fi
}

# Check AWS credentials and permissions
check_aws_credentials() {
    if ! aws sts get-caller-identity &> /dev/null; then
        handle_error "AWS credentials are not configured. Please run 'aws configure' first."
    fi

    # Check required permissions
    REQUIRED_PERMS=(
        "ec2:CreateVpc"
        "ec2:CreateSubnet"
        "ec2:CreateSecurityGroup"
        "ecs:CreateCluster"
        "ecs:CreateService"
        "iam:CreateRole"
        "ssm:PutParameter"
        "secretsmanager:CreateSecret"
    )

    for perm in "${REQUIRED_PERMS[@]}"; do
        if ! aws iam simulate-principal-policy \
            --policy-source-arn $(aws sts get-caller-identity --query Arn --output text) \
            --action-names $perm &> /dev/null; then
            handle_error "Missing required permission: $perm"
        fi
    done
}

# Wait for resource status
wait_for_status() {
    local resource_type=$1
    local resource_id=$2
    local desired_status=$3
    local max_attempts=$4
    local interval=$5

    local attempts=0
    while [ $attempts -lt $max_attempts ]; do
        local current_status
        case $resource_type in
            "vpc")
                current_status=$(aws ec2 describe-vpcs --vpc-ids $resource_id --query 'Vpcs[0].State' --output text)
                ;;
            "subnet")
                current_status=$(aws ec2 describe-subnets --subnet-ids $resource_id --query 'Subnets[0].State' --output text)
                ;;
            "service")
                current_status=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $resource_id --query 'services[0].status' --output text)
                ;;
            *)
                handle_error "Unknown resource type: $resource_type"
                ;;
        esac

        if [ "$current_status" = "$desired_status" ]; then
            echo -e "${GREEN}$resource_type $resource_id is $desired_status${NC}"
            return 0
        fi

        echo -e "${YELLOW}Waiting for $resource_type $resource_id to be $desired_status... (Attempt $((attempts+1))/$max_attempts)${NC}"
        sleep $interval
        ((attempts++))
    done

    handle_error "Timeout waiting for $resource_type $resource_id to reach $desired_status"
}

# Check if file exists
check_file_exists() {
    if [ ! -f "$1" ]; then
        handle_error "File not found: $1"
    fi
}

# Check if resource exists
check_resource_exists() {
    local resource_type=$1
    local resource_name=$2

    case $resource_type in
        "vpc")
            aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$resource_name" --query 'Vpcs[0].VpcId' --output text
            ;;
        "subnet")
            aws ec2 describe-subnets --filters "Name=tag:Name,Values=$resource_name" --query 'Subnets[0].SubnetId' --output text
            ;;
        "security-group")
            aws ec2 describe-security-groups --filters "Name=group-name,Values=$resource_name" --query 'SecurityGroups[0].GroupId' --output text
            ;;
        "cluster")
            aws ecs describe-clusters --clusters $resource_name --query 'clusters[0].status' --output text
            ;;
        "service")
            aws ecs describe-services --cluster $CLUSTER_NAME --services $resource_name --query 'services[0].status' --output text
            ;;
        *)
            handle_error "Unknown resource type: $resource_type"
            ;;
    esac
}