#!/bin/bash

# No need to source config.sh and utils.sh here as they're sourced in setup-aws.sh

# Setup ECS Cluster
setup_ecs_cluster() {
    echo -e "${YELLOW}Setting up ECS Cluster...${NC}"

    CLUSTER_STATUS=$(check_resource_exists "cluster" "$CLUSTER_NAME")

    if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
        echo -e "${GREEN}ECS cluster already exists${NC}"
        return 0
    fi

    aws ecs create-cluster \
        --cluster-name $CLUSTER_NAME \
        --region ${AWS_REGION} || handle_error "Failed to create ECS cluster"

    echo -e "${GREEN}ECS cluster created successfully${NC}"
}

# Setup ECS Service
setup_ecs_service() {
    echo -e "${YELLOW}Setting up ECS Service with enhanced configuration...${NC}"

    # Check if cluster exists and is active
    CLUSTER_STATUS=$(check_resource_exists "cluster" "$CLUSTER_NAME")
    if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
        handle_error "ECS cluster is not active. Please create the cluster first."
    fi

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
        --cluster $CLUSTER_NAME \
        --services $SERVICE_NAME \
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
        --cluster $CLUSTER_NAME \
        --service-name $SERVICE_NAME \
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
    wait_for_status "service" $SERVICE_NAME "ACTIVE" 30 10

    echo -e "${GREEN}ECS service created successfully with enhanced configuration${NC}"
}

# Delete ECS Service
delete_ecs_service() {
    echo -e "${YELLOW}Deleting ECS Service...${NC}"

    SERVICE_STATUS=$(check_resource_exists "service" "$SERVICE_NAME")

    if [ "$SERVICE_STATUS" = "ACTIVE" ]; then
        echo "Deleting ECS service..."
        aws ecs delete-service \
            --cluster $CLUSTER_NAME \
            --service $SERVICE_NAME \
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

    CLUSTER_STATUS=$(check_resource_exists "cluster" "$CLUSTER_NAME")

    if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
        echo "Deleting ECS cluster..."
        aws ecs delete-cluster \
            --cluster $CLUSTER_NAME \
            --region ${AWS_REGION} || handle_error "Failed to delete ECS cluster"
        echo -e "${GREEN}ECS cluster deleted successfully${NC}"
    else
        echo -e "${GREEN}ECS cluster does not exist${NC}"
    fi
}