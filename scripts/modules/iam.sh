#!/bin/bash

# No need to source config.sh and utils.sh here as they're sourced in setup-aws.sh

# Setup OIDC Provider
setup_oidc_provider() {
    echo -e "${YELLOW}Setting up OIDC Provider...${NC}"

    # Check if OIDC provider already exists
    OIDC_PROVIDER_ARN=$(aws iam list-open-id-connect-providers \
        --query "OpenIDConnectProviderList[?contains(Arn, 'github')].Arn" \
        --output text)

    if [ -n "$OIDC_PROVIDER_ARN" ]; then
        echo -e "${GREEN}OIDC provider already exists: $OIDC_PROVIDER_ARN${NC}"
        return 0
    fi

    # Get GitHub OIDC thumbprint
    echo "Getting GitHub OIDC thumbprint..."
    THUMBPRINT=$(openssl s_client -servername token.actions.githubusercontent.com -showcerts -connect token.actions.githubusercontent.com:443 </dev/null 2>/dev/null |
                 openssl x509 -fingerprint -noout |
                 sed -e "s/.*Fingerprint=//g" -e "s/://g" | tr '[:upper:]' '[:lower:]')

    if [ -z "$THUMBPRINT" ]; then
        handle_error "Failed to get GitHub OIDC thumbprint"
    fi

    # Create OIDC provider
    echo "Creating OIDC provider..."
    OIDC_PROVIDER_ARN=$(aws iam create-open-id-connect-provider \
        --url "https://token.actions.githubusercontent.com" \
        --client-id-list "sts.amazonaws.com" \
        --thumbprint-list "$THUMBPRINT" \
        --query "OpenIDConnectProviderArn" \
        --output text) || handle_error "Failed to create OIDC provider"

    echo -e "${GREEN}OIDC provider created successfully: $OIDC_PROVIDER_ARN${NC}"

    # Export for use in other functions
    export OIDC_PROVIDER_ARN
}

# Setup IAM Role
setup_iam_role() {
    echo -e "${YELLOW}Setting up IAM Role...${NC}"

    # Check if role already exists
    ROLE_EXISTS=$(aws iam get-role --role-name azni-ecs-xray-taskrole 2>/dev/null)

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}IAM task role already exists${NC}"
        return 0
    fi

    # Create trust policy document
    echo "Creating trust policy document..."
    cat > /tmp/trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                },
                "StringLike": {
                    "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:*"
                }
            }
        }
    ]
}
EOF

    # Create permissions policy document
    echo "Creating permissions policy document..."
    cat > /tmp/permissions-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "ecr:BatchCheckLayerAvailability",
                "ecr:PutImage",
                "ecr:InitiateLayerUpload",
                "ecr:UploadLayerPart",
                "ecr:CompleteLayerUpload",
                "ecr:GetAuthorizationToken"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ssm:GetParameters"
            ],
            "Resource": "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter/azni/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue"
            ],
            "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:azni/*"
        }
    ]
}
EOF

    # Check if IAM task role already exists
    echo "Checking if IAM task role already exists..."
    ROLE_EXISTS=$(aws iam get-role --role-name azni-ecs-xray-taskrole 2>/dev/null)

    if [ $? -ne 0 ]; then
        # Create IAM task role if it doesn't exist
        echo "Creating IAM task role..."
        ROLE_ARN=$(aws iam create-role \
            --role-name azni-ecs-xray-taskrole \
            --assume-role-policy-document file:///tmp/trust-policy.json \
            --query "Role.Arn" \
            --output text) || handle_error "Failed to create IAM task role"
    else
        echo "IAM task role already exists"
        ROLE_ARN=$(aws iam get-role \
            --role-name azni-ecs-xray-taskrole \
            --query "Role.Arn" \
            --output text)

        # Update trust policy
        echo "Updating trust policy..."
        aws iam update-assume-role-policy \
            --role-name azni-ecs-xray-taskrole \
            --policy-document file:///tmp/trust-policy.json || handle_error "Failed to update trust policy"
    fi

    # Check if IAM policy already exists
    echo "Checking if IAM policy already exists..."
    POLICY_ARN=$(aws iam list-policies \
        --query "Policies[?PolicyName=='github-actions-policy'].Arn" \
        --output text)

    if [ -z "$POLICY_ARN" ]; then
        # Create IAM policy if it doesn't exist
        echo "Creating IAM policy..."
        POLICY_ARN=$(aws iam create-policy \
            --policy-name github-actions-policy \
            --policy-document file:///tmp/permissions-policy.json \
            --query "Policy.Arn" \
            --output text) || handle_error "Failed to create IAM policy"
    else
        echo "IAM policy already exists: $POLICY_ARN"
    fi

    # Check if policy is already attached to the task role
    POLICY_ATTACHED=$(aws iam list-attached-role-policies \
        --role-name azni-ecs-xray-taskrole \
        --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyArn" \
        --output text)

    if [ -z "$POLICY_ATTACHED" ]; then
        # Attach policy to task role if not already attached
        echo "Attaching policy to task role..."
        aws iam attach-role-policy \
            --role-name azni-ecs-xray-taskrole \
            --policy-arn "$POLICY_ARN" || handle_error "Failed to attach policy to task role"
    else
        echo "Policy is already attached to the task role"
    fi

    # Check if ECS task execution role exists
    TASK_ROLE_EXISTS=$(aws iam get-role --role-name azni-ecs-xray-taskexecutionrole 2>/dev/null)

    if [ $? -ne 0 ]; then
        # Create ECS task execution role
        echo "Creating ECS task execution role..."
        cat > /tmp/ecs-task-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ecs-tasks.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

        aws iam create-role \
            --role-name azni-ecs-xray-taskexecutionrole \
            --assume-role-policy-document file:///tmp/ecs-task-trust-policy.json || handle_error "Failed to create ECS task execution role"
    fi

    # Attach required managed policies to the execution role
    echo "Attaching required managed policies to the execution role..."

    # 1. AmazonECSTaskExecutionRolePolicy
    POLICY_ATTACHED=$(aws iam list-attached-role-policies \
        --role-name azni-ecs-xray-taskexecutionrole \
        --query "AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy'].PolicyArn" \
        --output text)

    if [ -z "$POLICY_ATTACHED" ]; then
        echo "Attaching AmazonECSTaskExecutionRolePolicy..."
        aws iam attach-role-policy \
            --role-name azni-ecs-xray-taskexecutionrole \
            --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || handle_error "Failed to attach AmazonECSTaskExecutionRolePolicy"
    else
        echo "AmazonECSTaskExecutionRolePolicy is already attached to the role"
    fi

    # 2. AmazonSSMReadOnlyAccess
    POLICY_ATTACHED=$(aws iam list-attached-role-policies \
        --role-name azni-ecs-xray-taskexecutionrole \
        --query "AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess'].PolicyArn" \
        --output text)

    if [ -z "$POLICY_ATTACHED" ]; then
        echo "Attaching AmazonSSMReadOnlyAccess..."
        aws iam attach-role-policy \
            --role-name azni-ecs-xray-taskexecutionrole \
            --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess || handle_error "Failed to attach AmazonSSMReadOnlyAccess"
    else
        echo "AmazonSSMReadOnlyAccess is already attached to the role"
    fi

    # 3. SecretsManagerReadWrite
    POLICY_ATTACHED=$(aws iam list-attached-role-policies \
        --role-name azni-ecs-xray-taskexecutionrole \
        --query "AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/SecretsManagerReadWrite'].PolicyArn" \
        --output text)

    if [ -z "$POLICY_ATTACHED" ]; then
        echo "Attaching SecretsManagerReadWrite..."
        aws iam attach-role-policy \
            --role-name azni-ecs-xray-taskexecutionrole \
            --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite || handle_error "Failed to attach SecretsManagerReadWrite"
    else
        echo "SecretsManagerReadWrite is already attached to the role"
    fi

    # Add X-Ray permissions to task role using AWS managed policy
    echo "Adding X-Ray permissions to task role using AWS managed policy..."
    XRAY_POLICY_ARN="arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"

    # Attach X-Ray policy to task role
    POLICY_ATTACHED=$(aws iam list-attached-role-policies \
        --role-name azni-ecs-xray-taskrole \
        --query "AttachedPolicies[?PolicyArn=='$XRAY_POLICY_ARN'].PolicyArn" \
        --output text)

    if [ -z "$POLICY_ATTACHED" ]; then
        # Attach policy to role if not already attached
        echo "Attaching X-Ray access policy to task role..."
        aws iam attach-role-policy \
            --role-name azni-ecs-xray-taskrole \
            --policy-arn "$XRAY_POLICY_ARN" || handle_error "Failed to attach X-Ray access policy to task role"
    else
        echo "X-Ray access policy is already attached to the task role"
    fi

    # Attach X-Ray policy to execution role
    POLICY_ATTACHED=$(aws iam list-attached-role-policies \
        --role-name azni-ecs-xray-taskexecutionrole \
        --query "AttachedPolicies[?PolicyArn=='$XRAY_POLICY_ARN'].PolicyArn" \
        --output text)

    if [ -z "$POLICY_ATTACHED" ]; then
        # Attach policy to role if not already attached
        echo "Attaching X-Ray access policy to execution role..."
        aws iam attach-role-policy \
            --role-name azni-ecs-xray-taskexecutionrole \
            --policy-arn "$XRAY_POLICY_ARN" || handle_error "Failed to attach X-Ray access policy to execution role"
    else
        echo "X-Ray access policy is already attached to the execution role"
    fi

    # Clean up temporary files
    rm -f /tmp/trust-policy.json /tmp/permissions-policy.json /tmp/ecs-task-trust-policy.json

    echo -e "${GREEN}IAM role and policies created successfully${NC}"

    # Export for use in other functions
    export ROLE_ARN
}

# Delete IAM Role
delete_iam_role() {
    echo -e "${YELLOW}Deleting IAM Role...${NC}"

    # Check if task role exists
    ROLE_EXISTS=$(aws iam get-role --role-name azni-ecs-xray-taskrole 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo -e "${GREEN}IAM task role does not exist${NC}"
        return 0
    fi

    # Get attached policies
    ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
        --role-name azni-ecs-xray-taskrole \
        --query "AttachedPolicies[*].PolicyArn" \
        --output text)

    # Detach policies
    for POLICY_ARN in $ATTACHED_POLICIES; do
        echo "Detaching policy $POLICY_ARN from task role..."
        aws iam detach-role-policy \
            --role-name azni-ecs-xray-taskrole \
            --policy-arn "$POLICY_ARN" || handle_error "Failed to detach policy from task role"
    done

    # Delete custom policies
    CUSTOM_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/github-actions-policy"
    if aws iam get-policy --policy-arn "$CUSTOM_POLICY_ARN" &>/dev/null; then
        echo "Deleting custom policy..."
        aws iam delete-policy \
            --policy-arn "$CUSTOM_POLICY_ARN" || handle_error "Failed to delete custom policy"
    fi

    # Detach AWS X-Ray managed policy from task role
    XRAY_POLICY_ARN="arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
    echo "Detaching X-Ray policy from task role..."
    aws iam detach-role-policy \
        --role-name azni-ecs-xray-taskrole \
        --policy-arn "$XRAY_POLICY_ARN" || echo "X-Ray policy not attached to azni-ecs-xray-taskrole"

    # Detach managed policies from execution role
    echo "Detaching managed policies from execution role..."

    # Check if execution role exists
    TASK_ROLE_EXISTS=$(aws iam get-role --role-name azni-ecs-xray-taskexecutionrole 2>/dev/null)

    if [ $? -eq 0 ]; then
        # 1. Detach AmazonECSTaskExecutionRolePolicy
        aws iam detach-role-policy \
            --role-name azni-ecs-xray-taskexecutionrole \
            --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || echo "AmazonECSTaskExecutionRolePolicy not attached to azni-ecs-xray-taskexecutionrole"

        # 2. Detach AmazonSSMReadOnlyAccess
        aws iam detach-role-policy \
            --role-name azni-ecs-xray-taskexecutionrole \
            --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess || echo "AmazonSSMReadOnlyAccess not attached to azni-ecs-xray-taskexecutionrole"

        # 3. Detach SecretsManagerReadWrite
        aws iam detach-role-policy \
            --role-name azni-ecs-xray-taskexecutionrole \
            --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite || echo "SecretsManagerReadWrite not attached to azni-ecs-xray-taskexecutionrole"

        # 4. Detach X-Ray policy
        aws iam detach-role-policy \
            --role-name azni-ecs-xray-taskexecutionrole \
            --policy-arn "$XRAY_POLICY_ARN" || echo "X-Ray policy not attached to azni-ecs-xray-taskexecutionrole"

        # Delete execution role
        echo "Deleting execution role..."
        aws iam delete-role \
            --role-name azni-ecs-xray-taskexecutionrole || echo "Failed to delete azni-ecs-xray-taskexecutionrole"
    else
        echo "Execution role does not exist"
    fi

    # Delete task role
    echo "Deleting task role..."
    aws iam delete-role \
        --role-name azni-ecs-xray-taskrole || handle_error "Failed to delete task role"

    echo -e "${GREEN}IAM role and policies deleted successfully${NC}"
}

# Delete OIDC Provider
delete_oidc_provider() {
    echo -e "${YELLOW}Deleting OIDC Provider...${NC}"

    # Check if OIDC provider exists
    OIDC_PROVIDER_ARN=$(aws iam list-open-id-connect-providers \
        --query "OpenIDConnectProviderList[?contains(Arn, 'github')].Arn" \
        --output text)

    if [ -z "$OIDC_PROVIDER_ARN" ]; then
        echo -e "${GREEN}OIDC provider does not exist${NC}"
        return 0
    fi

    # Delete OIDC provider
    echo "Deleting OIDC provider..."
    aws iam delete-open-id-connect-provider \
        --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" || handle_error "Failed to delete OIDC provider"

    echo -e "${GREEN}OIDC provider deleted successfully${NC}"
}
