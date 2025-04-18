#!/bin/bash

# Set script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Source all modules
source "$SCRIPT_DIR/modules/config.sh"
source "$SCRIPT_DIR/modules/utils.sh"
source "$SCRIPT_DIR/modules/vpc.sh"
source "$SCRIPT_DIR/modules/ecs.sh"
source "$SCRIPT_DIR/modules/secrets.sh"
source "$SCRIPT_DIR/modules/iam.sh"

# Configuration
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-"255945442255"}
AWS_REGION=${AWS_REGION:-"us-east-1"}
REPO_NAME=${REPO_NAME:-"azni-flask-private-repository"}
GITHUB_REPO=${GITHUB_REPO:-"azniosman/Assignment-3.5"}
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TASK_DEFINITION_FILE="${PROJECT_ROOT}/task-definition.json"

# Security Configuration
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
ALLOWED_IP_RANGES="0.0.0.0/0"  # In production, restrict this to specific IPs
CONTAINER_PORT=8080
MIN_TASK_COUNT=1
MAX_TASK_COUNT=2
DESIRED_TASK_COUNT=1
CPU_UNITS=256
MEMORY_MB=512

# Colors are already defined above

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

# Non-fatal error handling function
local_error_handler() {
    echo -e "${RED}Warning: $1${NC}"
    return 0
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
                current_status=$(aws ecs describe-services --cluster azni-flask-xray-cluster --services $resource_id --query 'services[0].status' --output text)
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

# Setup VPC Resources with enhanced security
setup_vpc_resources() {
    echo -e "${YELLOW}Setting up VPC resources with enhanced security...${NC}"

    # Create VPC with tags
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block $VPC_CIDR \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=azni-flask-vpc},{Key=Environment,Value=Development},{Key=ManagedBy,Value=Script}]" \
        --query 'Vpc.VpcId' \
        --output text) || handle_error "Failed to create VPC"

    # Enable DNS hostnames and DNS support
    aws ec2 modify-vpc-attribute \
        --vpc-id $VPC_ID \
        --enable-dns-hostnames || handle_error "Failed to enable DNS hostnames"

    aws ec2 modify-vpc-attribute \
        --vpc-id $VPC_ID \
        --enable-dns-support || handle_error "Failed to enable DNS support"

    # Create Internet Gateway with tags
    IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=azni-flask-igw},{Key=Environment,Value=Development}]" \
        --query 'InternetGateway.InternetGatewayId' \
        --output text) || handle_error "Failed to create Internet Gateway"

    # Attach Internet Gateway to VPC
    aws ec2 attach-internet-gateway \
        --vpc-id $VPC_ID \
        --internet-gateway-id $IGW_ID || handle_error "Failed to attach Internet Gateway"

    # Create Subnet with tags
    SUBNET_ID=$(aws ec2 create-subnet \
        --vpc-id $VPC_ID \
        --cidr-block $SUBNET_CIDR \
        --availability-zone ${AWS_REGION}a \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=azni-flask-subnet},{Key=Environment,Value=Development}]" \
        --query 'Subnet.SubnetId' \
        --output text) || handle_error "Failed to create subnet"

    # Create Security Group with restrictive rules
    SG_ID=$(aws ec2 create-security-group \
        --group-name azni-flask-sg \
        --description "Security group for Flask application" \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=azni-flask-sg},{Key=Environment,Value=Development}]" \
        --query 'GroupId' \
        --output text) || handle_error "Failed to create security group"

    # Add restrictive inbound rules
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port $CONTAINER_PORT \
        --cidr $ALLOWED_IP_RANGES || handle_error "Failed to add security group ingress rule"

    # Create Route Table with tags
    RT_ID=$(aws ec2 create-route-table \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=azni-flask-rt},{Key=Environment,Value=Development}]" \
        --query 'RouteTable.RouteTableId' \
        --output text) || handle_error "Failed to create route table"

    # Add route to Internet Gateway
    aws ec2 create-route \
        --route-table-id $RT_ID \
        --destination-cidr-block 0.0.0.0/0 \
        --gateway-id $IGW_ID || handle_error "Failed to create route"

    # Associate subnet with route table
    aws ec2 associate-route-table \
        --subnet-id $SUBNET_ID \
        --route-table-id $RT_ID || handle_error "Failed to associate route table"

    # Wait for resources to be available
    wait_for_status "vpc" $VPC_ID "available" 30 5
    wait_for_status "subnet" $SUBNET_ID "available" 30 5

    # Export variables for use in other functions
    export VPC_ID
    export SUBNET_ID
    export SG_ID

    echo -e "${GREEN}VPC resources created successfully with enhanced security${NC}"
}

# Setup ECS Service with enhanced configuration
setup_ecs_service() {
    echo -e "${YELLOW}Setting up ECS Service with enhanced configuration...${NC}"

    # Check if task definition file exists
    check_file_exists "$TASK_DEFINITION_FILE"

    # First, register the task definition
    echo "Registering task definition..."
    TASK_DEF_ARN=$(aws ecs register-task-definition \
        --cli-input-json "file://${TASK_DEFINITION_FILE}" \
        --region ${AWS_REGION} \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text) || handle_error "Failed to register task definition"

    if [ -z "$TASK_DEF_ARN" ]; then
        handle_error "Failed to get task definition ARN"
    fi

    # Wait for task definition to be available
    echo "Waiting for task definition to be available..."
    MAX_ATTEMPTS=30
    ATTEMPT=1
    while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
        TASK_STATUS=$(aws ecs describe-task-definition \
            --task-definition "$TASK_DEF_ARN" \
            --region ${AWS_REGION} \
            --query 'taskDefinition.status' \
            --output text 2>/dev/null)

        if [ "$TASK_STATUS" = "ACTIVE" ]; then
            echo -e "${GREEN}Task definition is now active${NC}"
            break
        fi

        if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
            handle_error "Timeout waiting for task definition to become active"
        fi

        echo -e "${YELLOW}Waiting for task definition to become active... (Attempt $ATTEMPT/$MAX_ATTEMPTS)${NC}"
        sleep 5
        ((ATTEMPT++))
    done

    # Check if service exists
    SERVICE_STATUS=$(aws ecs describe-services \
        --cluster azni-flask-xray-cluster \
        --services azni-flask-service \
        --region ${AWS_REGION} \
        --query 'services[0].status' \
        --output text 2>/dev/null)

    if [ "$SERVICE_STATUS" = "ACTIVE" ]; then
        echo -e "${GREEN}ECS service already exists${NC}"
        return 0
    fi

    # Create service with enhanced configuration
    echo "Creating ECS service..."
    aws ecs create-service \
        --cluster azni-flask-xray-cluster \
        --service-name azni-flask-service \
        --task-definition "$TASK_DEF_ARN" \
        --desired-count $DESIRED_TASK_COUNT \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
        --deployment-configuration "maximumPercent=200,minimumHealthyPercent=50" \
        --health-check-grace-period-seconds 60 \
        --scheduling-strategy REPLICA \
        --enable-execute-command \
        --region ${AWS_REGION} || handle_error "Failed to create ECS service"

    # Wait for service to stabilize
    wait_for_status "service" azni-flask-service "ACTIVE" 30 10

    echo -e "${GREEN}ECS service created successfully with enhanced configuration${NC}"
}

# Delete ECS Service
delete_ecs_service() {
    echo -e "${YELLOW}Deleting ECS Service...${NC}"

    SERVICE_STATUS=$(aws ecs describe-services \
        --cluster azni-flask-xray-cluster \
        --services azni-flask-service \
        --region ${AWS_REGION} \
        --query 'services[0].status' \
        --output text 2>/dev/null)

    if [ "$SERVICE_STATUS" = "ACTIVE" ]; then
        echo "Deleting ECS service..."
        aws ecs delete-service \
            --cluster azni-flask-xray-cluster \
            --service azni-flask-service \
            --force \
            --region ${AWS_REGION} || handle_error "Failed to delete ECS service"
        echo -e "${GREEN}ECS service deleted successfully${NC}"
    else
        echo -e "${GREEN}ECS service does not exist${NC}"
    fi
}

# Delete ECS Cluster
delete_ecs_cluster() {
    echo -e "${YELLOW}Deleting ECS Cluster...${NC}"

    CLUSTER_STATUS=$(aws ecs describe-clusters \
        --clusters azni-flask-xray-cluster \
        --region ${AWS_REGION} \
        --query 'clusters[0].status' \
        --output text 2>/dev/null)

    if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
        echo "Deleting ECS cluster..."
        aws ecs delete-cluster \
            --cluster azni-flask-xray-cluster \
            --region ${AWS_REGION} || handle_error "Failed to delete ECS cluster"
        echo -e "${GREEN}ECS cluster deleted successfully${NC}"
    else
        echo -e "${GREEN}ECS cluster does not exist${NC}"
    fi
}

# Delete SSM Parameter
delete_ssm_parameter() {
    echo -e "${YELLOW}Deleting SSM Parameter...${NC}"

    if aws ssm get-parameter --name "/azni/config" --region ${AWS_REGION} &> /dev/null; then
        echo "Deleting SSM parameter..."
        aws ssm delete-parameter \
            --name "/azni/config" \
            --region ${AWS_REGION} || handle_error "Failed to delete SSM parameter"
        echo -e "${GREEN}SSM parameter deleted successfully${NC}"
    else
        echo -e "${GREEN}SSM parameter does not exist${NC}"
    fi
}

# Delete Secrets Manager Secret
delete_secrets_manager() {
    echo -e "${YELLOW}Deleting Secrets Manager secret...${NC}"

    if aws secretsmanager describe-secret --secret-id "azni/db_password" --region ${AWS_REGION} &> /dev/null; then
        echo "Deleting Secrets Manager secret..."
        aws secretsmanager delete-secret \
            --secret-id "azni/db_password" \
            --force-delete-without-recovery \
            --region ${AWS_REGION} || handle_error "Failed to delete Secrets Manager secret"
        echo -e "${GREEN}Secrets Manager secret deleted successfully${NC}"
    else
        echo -e "${GREEN}Secrets Manager secret does not exist${NC}"
    fi
}

# Delete VPC Resources function is now in vpc.sh module

# Check if file exists
check_file_exists() {
    if [ ! -f "$1" ]; then
        handle_error "File not found: $1"
    fi
}

# Setup all resources in sequence
setup_all_resources() {
    echo -e "${YELLOW}Setting up all resources in sequence...${NC}"

    # 1. Setup OIDC Provider (required for IAM role)
    echo -e "\n${YELLOW}Step 1: Setting up OIDC Provider...${NC}"
    setup_oidc_provider

    # 2. Setup IAM Role (required for ECS tasks and GitHub Actions)
    echo -e "\n${YELLOW}Step 2: Setting up IAM Role...${NC}"
    setup_iam_role

    # 3. Setup VPC Resources (required for ECS)
    echo -e "\n${YELLOW}Step 3: Setting up VPC Resources...${NC}"
    setup_vpc_resources

    # 4. Setup ECS Cluster (required for ECS service)
    echo -e "\n${YELLOW}Step 4: Setting up ECS Cluster...${NC}"
    setup_ecs_cluster

    # 5. Setup SSM Parameter (required for ECS task)
    echo -e "\n${YELLOW}Step 5: Setting up SSM Parameter...${NC}"
    setup_ssm_parameter

    # 6. Setup Secrets Manager (required for ECS task)
    echo -e "\n${YELLOW}Step 6: Setting up Secrets Manager...${NC}"
    setup_secrets_manager

    # 7. Setup ECS Service (depends on all above)
    echo -e "\n${YELLOW}Step 7: Setting up ECS Service...${NC}"
    setup_ecs_service

    echo -e "\n${GREEN}All resources have been set up successfully!${NC}"
}

# Delete all resources in reverse sequence
delete_all_resources() {
    echo -e "${YELLOW}Deleting all resources in reverse sequence...${NC}"

    # 1. Delete ECS Service (must be deleted before cluster)
    echo -e "\n${YELLOW}Step 1: Deleting ECS Service...${NC}"
    delete_ecs_service

    # 2. Delete ECS Cluster (must be deleted before VPC)
    echo -e "\n${YELLOW}Step 2: Deleting ECS Cluster...${NC}"
    delete_ecs_cluster

    # 3. Delete VPC Resources (must be deleted after all dependent resources)
    echo -e "\n${YELLOW}Step 3: Deleting VPC Resources...${NC}"
    delete_vpc_resources

    # 4. Delete SSM Parameter
    echo -e "\n${YELLOW}Step 4: Deleting SSM Parameter...${NC}"
    delete_ssm_parameter

    # 5. Delete Secrets Manager Secret
    echo -e "\n${YELLOW}Step 5: Deleting Secrets Manager Secret...${NC}"
    delete_secrets_manager

    # 6. Delete IAM Role
    echo -e "\n${YELLOW}Step 6: Deleting IAM Role...${NC}"
    delete_iam_role

    # 7. Delete OIDC Provider
    echo -e "\n${YELLOW}Step 7: Deleting OIDC Provider...${NC}"
    delete_oidc_provider

    echo -e "\n${GREEN}All resources have been deleted successfully!${NC}"
}

# Main menu
show_menu() {
    echo -e "\n${YELLOW}AWS Setup Menu${NC}"
    echo "1. Setup OIDC Provider"
    echo "2. Setup IAM Role"
    echo "3. Setup VPC Resources"
    echo "4. Setup ECS Cluster"
    echo "5. Setup SSM Parameter"
    echo "6. Setup Secrets Manager"
    echo "7. Setup ECS Service"
    echo "8. Setup All Resources (in sequence)"
    echo "9. Delete SSM Parameter"
    echo "10. Delete Secrets Manager Secret"
    echo "11. Delete ECS Service"
    echo "12. Delete ECS Cluster"
    echo "13. Delete VPC Resources"
    echo "14. Delete IAM Role"
    echo "15. Delete OIDC Provider"
    echo "16. Delete All Resources (in reverse sequence)"
    echo "17. Exit"
    echo -n "Enter your choice [1-17]: "
}

# Main function
main() {
    check_aws_cli
    check_aws_credentials

    while true; do
        show_menu
        read choice
        case $choice in
            1)
                setup_oidc_provider
                ;;
            2)
                setup_iam_role
                ;;
            3)
                setup_vpc_resources
                ;;
            4)
                setup_ecs_cluster
                ;;
            5)
                setup_ssm_parameter
                ;;
            6)
                setup_secrets_manager
                ;;
            7)
                setup_ecs_service
                ;;
            8)
                setup_all_resources
                ;;
            9)
                delete_ssm_parameter
                ;;
            10)
                delete_secrets_manager
                ;;
            11)
                delete_ecs_service
                ;;
            12)
                delete_ecs_cluster
                ;;
            13)
                delete_vpc_resources
                ;;
            14)
                delete_iam_role
                ;;
            15)
                delete_oidc_provider
                ;;
            16)
                delete_all_resources
                ;;
            17)
                echo -e "${GREEN}Exiting...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                ;;
        esac
    done
}

# Run main function
main