#!/bin/bash

# No need to source config.sh and utils.sh here as they're sourced in setup-aws.sh

# Setup ECR Repository
setup_ecr_repository() {
    echo -e "${YELLOW}Setting up ECR Repository...${NC}"

    # Check if repository already exists
    REPO_EXISTS=$(aws ecr describe-repositories \
        --repository-names $REPO_NAME \
        --region ${AWS_REGION} 2>/dev/null)

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}ECR repository already exists${NC}"
        return 0
    fi

    # Create ECR repository
    echo "Creating ECR repository..."
    REPO_URI=$(aws ecr create-repository \
        --repository-name $REPO_NAME \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256 \
        --region ${AWS_REGION} \
        --query 'repository.repositoryUri' \
        --output text) || handle_error "Failed to create ECR repository"

    echo -e "${GREEN}ECR repository created successfully: $REPO_URI${NC}"

    # Export for use in other functions
    export REPO_URI
}

# Delete ECR Repository
delete_ecr_repository() {
    echo -e "${YELLOW}Deleting ECR Repository...${NC}"

    # Check if repository exists
    REPO_EXISTS=$(aws ecr describe-repositories \
        --repository-names $REPO_NAME \
        --region ${AWS_REGION} 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo -e "${GREEN}ECR repository does not exist${NC}"
        return 0
    fi

    # Delete ECR repository
    echo "Deleting ECR repository..."
    aws ecr delete-repository \
        --repository-name $REPO_NAME \
        --force \
        --region ${AWS_REGION} || handle_error "Failed to delete ECR repository"

    echo -e "${GREEN}ECR repository deleted successfully${NC}"
}
