#!/bin/bash

# No need to source config.sh and utils.sh here as they're sourced in setup-aws.sh

# Setup SSM Parameter
setup_ssm_parameter() {
    echo -e "${YELLOW}Setting up SSM Parameter...${NC}"

    if aws ssm get-parameter --name "$SSM_PARAMETER_NAME" --region ${AWS_REGION} &> /dev/null; then
        echo -e "${GREEN}SSM parameter already exists${NC}"
        return 0
    fi

    aws ssm put-parameter \
        --name "$SSM_PARAMETER_NAME" \
        --value "MySSMConfig" \
        --type "String" \
        --region ${AWS_REGION} || handle_error "Failed to create SSM parameter"

    echo -e "${GREEN}SSM parameter created successfully${NC}"
}

# Setup Secrets Manager
setup_secrets_manager() {
    echo -e "${YELLOW}Setting up Secrets Manager...${NC}"

    if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region ${AWS_REGION} &> /dev/null; then
        echo -e "${GREEN}Secrets Manager secret already exists${NC}"
        return 0
    fi

    aws secretsmanager create-secret \
        --name "$SECRET_NAME" \
        --secret-string "{\"username\":\"admin\",\"password\":\"secret123\"}" \
        --region ${AWS_REGION} || handle_error "Failed to create Secrets Manager secret"

    echo -e "${GREEN}Secrets Manager secret created successfully${NC}"
}

# Delete SSM Parameter
delete_ssm_parameter() {
    echo -e "${YELLOW}Deleting SSM Parameter...${NC}"

    if aws ssm get-parameter --name "$SSM_PARAMETER_NAME" --region ${AWS_REGION} &> /dev/null; then
        echo "Deleting SSM parameter..."
        aws ssm delete-parameter \
            --name "$SSM_PARAMETER_NAME" \
            --region ${AWS_REGION} || handle_error "Failed to delete SSM parameter"
        echo -e "${GREEN}SSM parameter deleted successfully${NC}"
    else
        echo -e "${GREEN}SSM parameter does not exist${NC}"
    fi
}

# Delete Secrets Manager Secret
delete_secrets_manager() {
    echo -e "${YELLOW}Deleting Secrets Manager secret...${NC}"

    if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region ${AWS_REGION} &> /dev/null; then
        echo "Deleting Secrets Manager secret..."
        aws secretsmanager delete-secret \
            --secret-id "$SECRET_NAME" \
            --force-delete-without-recovery \
            --region ${AWS_REGION} || handle_error "Failed to delete Secrets Manager secret"
        echo -e "${GREEN}Secrets Manager secret deleted successfully${NC}"
    else
        echo -e "${GREEN}Secrets Manager secret does not exist${NC}"
    fi
}