#!/bin/bash

# No need to source config.sh and utils.sh here as they're sourced in setup-aws.sh

# Setup VPC Resources
setup_vpc_resources() {
    echo -e "${YELLOW}Setting up VPC resources with enhanced security...${NC}"

    # Create VPC with tags
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block $VPC_CIDR \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Environment,Value=Development},{Key=ManagedBy,Value=Script}]" \
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
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME},{Key=Environment,Value=Development}]" \
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
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$SUBNET_NAME},{Key=Environment,Value=Development}]" \
        --query 'Subnet.SubnetId' \
        --output text) || handle_error "Failed to create subnet"

    # Create Security Group with restrictive rules
    SG_ID=$(aws ec2 create-security-group \
        --group-name $SG_NAME \
        --description "Security group for Flask application" \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Environment,Value=Development}]" \
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
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$RT_NAME},{Key=Environment,Value=Development}]" \
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

# Delete VPC Resources with safety checks
delete_vpc_resources() {
    echo -e "${YELLOW}Deleting VPC resources with safety checks...${NC}"

    # Get VPC ID
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=azni-flask-vpc" \
        --query 'Vpcs[0].VpcId' \
        --output text)

    # Define a local error handler that doesn't exit the script
    local_error_handler() {
        echo -e "${RED}Warning: $1${NC}"
        return 0
    }

    if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
        echo -e "${GREEN}VPC resources do not exist${NC}"
        return 0
    fi

    # Check for running instances
    RUNNING_INSTANCES=$(aws ec2 describe-instances \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text)

    if [ -n "$RUNNING_INSTANCES" ]; then
        echo -e "${RED}Warning: Cannot delete VPC: Running instances found. Please terminate them first.${NC}"
        echo "Continuing with deletion attempt..."
    fi

    # Check for ECS tasks
    RUNNING_TASKS=$(aws ecs list-tasks \
        --cluster azni-flask-xray-cluster \
        --query 'taskArns[*]' \
        --output text)

    if [ -n "$RUNNING_TASKS" ]; then
        echo -e "${RED}Warning: Cannot delete VPC: Running ECS tasks found. Please stop them first.${NC}"
        echo "Continuing with deletion attempt..."
    fi

    # Get and delete Internet Gateway
    IGW_ID=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text)

    if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
        echo "Detaching Internet Gateway..."
        aws ec2 detach-internet-gateway \
            --vpc-id $VPC_ID \
            --internet-gateway-id $IGW_ID || local_error_handler "Failed to detach Internet Gateway"

        echo "Deleting Internet Gateway..."
        aws ec2 delete-internet-gateway \
            --internet-gateway-id $IGW_ID || local_error_handler "Failed to delete Internet Gateway"
    fi

    # Get subnet IDs but don't delete them yet
    SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[*].SubnetId' \
        --output text)

    # We'll delete the subnets after handling route tables

    # Get and delete Security Groups (except default)
    SECURITY_GROUPS=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text)

    for SG_ID in $SECURITY_GROUPS; do
        echo "Deleting Security Group $SG_ID..."
        aws ec2 delete-security-group \
            --group-id $SG_ID || local_error_handler "Failed to delete security group"
    done

    # Get and delete Network ACLs (except default)
    NETWORK_ACLS=$(aws ec2 describe-network-acls \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'NetworkAcls[?IsDefault!=`true`].NetworkAclId' \
        --output text)

    for NACL_ID in $NETWORK_ACLS; do
        echo "Deleting Network ACL $NACL_ID..."
        aws ec2 delete-network-acl \
            --network-acl-id $NACL_ID || local_error_handler "Failed to delete network ACL"
    done

    # Get and delete VPC Endpoints
    VPC_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'VpcEndpoints[*].VpcEndpointId' \
        --output text)

    for ENDPOINT_ID in $VPC_ENDPOINTS; do
        echo "Deleting VPC Endpoint $ENDPOINT_ID..."
        aws ec2 delete-vpc-endpoints \
            --vpc-endpoint-ids $ENDPOINT_ID || local_error_handler "Failed to delete VPC endpoint"
    done

    # Get and delete Route Tables (except main)
    ROUTE_TABLES=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
        --output text)

    for RT_ID in $ROUTE_TABLES; do
        # First, delete all non-default routes in the route table
        echo "Deleting routes from route table $RT_ID..."
        ROUTES=$(aws ec2 describe-route-tables \
            --route-table-id $RT_ID \
            --query 'RouteTables[0].Routes[?DestinationCidrBlock!=`'$VPC_CIDR'`].DestinationCidrBlock' \
            --output text)

        for ROUTE_CIDR in $ROUTES; do
            echo "Deleting route to $ROUTE_CIDR from route table $RT_ID..."
            aws ec2 delete-route \
                --route-table-id $RT_ID \
                --destination-cidr-block $ROUTE_CIDR || local_error_handler "Failed to delete route to $ROUTE_CIDR"
        done

        # Second, disassociate all subnets from the route table
        ASSOCIATIONS=$(aws ec2 describe-route-tables \
            --route-table-ids $RT_ID \
            --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
            --output text)

        for ASSOC_ID in $ASSOCIATIONS; do
            echo "Disassociating subnet from route table $RT_ID..."
            aws ec2 disassociate-route-table \
                --association-id $ASSOC_ID || local_error_handler "Failed to disassociate route table"
        done

        # Then delete the route table
        echo "Deleting Route Table $RT_ID..."
        aws ec2 delete-route-table \
            --route-table-id $RT_ID || local_error_handler "Failed to delete route table $RT_ID, will retry later"
    done

    # Retry deleting any remaining route tables
    echo "Checking for any remaining route tables..."
    REMAINING_ROUTE_TABLES=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
        --output text)

    if [ -n "$REMAINING_ROUTE_TABLES" ]; then
        echo "Found remaining route tables, attempting to delete again..."
        for RT_ID in $REMAINING_ROUTE_TABLES; do
            # Check for any remaining associations
            REMAINING_ASSOC=$(aws ec2 describe-route-tables \
                --route-table-ids $RT_ID \
                --query 'RouteTables[0].Associations[*].RouteTableAssociationId' \
                --output text)

            for ASSOC_ID in $REMAINING_ASSOC; do
                echo "Disassociating remaining association from route table $RT_ID..."
                aws ec2 disassociate-route-table \
                    --association-id $ASSOC_ID || local_error_handler "Failed to disassociate route table"
            done

            # Try to delete the route table again
            echo "Retrying deletion of route table $RT_ID..."
            aws ec2 delete-route-table \
                --route-table-id $RT_ID || local_error_handler "Still unable to delete route table $RT_ID"
        done
    fi

    # Try one more time with force option for any remaining route tables
    FINAL_ROUTE_TABLES=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
        --output text)

    if [ -n "$FINAL_ROUTE_TABLES" ]; then
        echo "Some route tables still exist. Proceeding with subnet deletion anyway..."
    fi

    # Now delete the subnets
    for SUBNET_ID in $SUBNETS; do
        echo "Deleting Subnet $SUBNET_ID..."
        aws ec2 delete-subnet \
            --subnet-id $SUBNET_ID || local_error_handler "Failed to delete subnet"
    done

    # Final check for any remaining dependencies
    echo "Checking for any remaining dependencies before deleting VPC..."
    sleep 5  # Give AWS some time to update the state

    # Try to delete any remaining route tables one last time
    LAST_ROUTE_TABLES=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
        --output text)

    for RT_ID in $LAST_ROUTE_TABLES; do
        echo "Final attempt to delete route table $RT_ID..."
        aws ec2 delete-route-table \
            --route-table-id $RT_ID || local_error_handler "Unable to delete route table $RT_ID"
    done

    # Check if there are any remaining dependencies
    DEPENDENCIES=$(aws ec2 describe-vpc-attribute \
        --vpc-id $VPC_ID \
        --attribute enableDnsSupport 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "VPC $VPC_ID no longer exists, skipping deletion"
    else
        # Delete VPC
        echo "Deleting VPC..."
        aws ec2 delete-vpc \
            --vpc-id $VPC_ID || local_error_handler "Failed to delete VPC. You may need to manually check for remaining dependencies."
    fi

    echo -e "${GREEN}VPC resources deleted successfully${NC}"
}