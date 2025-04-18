# Container Orchestration with ECS

This project demonstrates a Flask application containerized with Docker and deployed using AWS ECS. The repository includes GitHub Actions workflow for automated builds and deployments to Amazon ECR, along with secure parameter and secret management using AWS SSM Parameter Store and Secrets Manager.

## Project Structure

```
.
├── .github/
│   └── workflows/
│       └── docker-push.yml    # GitHub Actions workflow
├── scripts/
│   └── setup-aws.sh          # AWS setup script (OIDC, IAM, SSM, Secrets)
├── app.py                     # Flask application
├── Dockerfile                 # Docker configuration
├── requirements.txt           # Python dependencies
├── task-definition.json       # ECS Task Definition
└── README.md                 # Project documentation
```

## Prerequisites

- AWS Account with appropriate permissions
- AWS CLI configured with credentials
- Docker installed locally
- GitHub repository access

## Setup Instructions

### 1. AWS Setup

The repository includes a menu-driven setup script in the `scripts` directory that handles AWS resource configuration:

```bash
# Make the script executable
chmod +x scripts/setup-aws.sh

# Run the setup script
./scripts/setup-aws.sh
```

The script provides the following options:

1. Setup OIDC Provider
2. Setup IAM Role
3. Setup SSM Parameter
4. Setup Secrets Manager
5. Setup All (OIDC Provider, IAM Role, SSM Parameter, Secrets Manager)
6. Exit

The script includes:

- Error handling and validation
- AWS CLI and credentials checks
- Color-coded output for better visibility
- Automatic cleanup of temporary files

#### AWS Resources Created

1. **OIDC Provider**

   - Enables secure authentication between GitHub Actions and AWS
   - Uses GitHub's token service
   - Trusts GitHub Actions to assume IAM roles

2. **IAM Role**

   - Grants necessary permissions for:
     - ECR access (push/pull images)
     - SSM Parameter Store access
     - Secrets Manager access
   - Used by GitHub Actions for deployment
   - Includes trust relationship with GitHub OIDC provider

3. **SSM Parameter Store**

   - Stores secure database connection URL
   - Parameter path: `/azni/config`
   - Type: SecureString
   - Accessible by ECS tasks and GitHub Actions
   - Encrypted at rest using AWS KMS
   - Versioned for change tracking

4. **Secrets Manager**
   - Stores database credentials
   - Secret name: `azni/db_password`
   - Contains username and password
   - Accessible by ECS tasks and GitHub Actions
   - Automatically rotated (if configured)
   - Encrypted at rest using AWS KMS

### 2. Managing Parameters and Secrets

#### SSM Parameter Management

View parameter:

```bash
aws ssm get-parameter --name "/azni/config" --with-decryption
```

Update parameter:

```bash
aws ssm put-parameter --name "/azni/config" --value "new-value" --type "SecureString" --overwrite
```

List parameters:

```bash
aws ssm describe-parameters --parameter-filters "Key=Name,Values=/azni/config"
```

#### Secrets Manager Management

View secret:

```bash
aws secretsmanager get-secret-value --secret-id "azni/db_password"
```

Update secret:

```bash
aws secretsmanager update-secret --secret-id "azni/db_password" --secret-string '{"username":"newuser","password":"newpass"}'
```

List secrets:

```bash
aws secretsmanager list-secrets --filters "Key=name,Values=azni/db_password"
```

### 3. GitHub Actions Workflow

The repository includes a GitHub Actions workflow (`.github/workflows/docker-push.yml`) that:

- Triggers on pushes to the main branch
- Builds the Docker image
- Tags the image with both `latest` and the commit SHA
- Pushes the image to ECR
- Uses OIDC for secure authentication

#### OIDC Authentication

The workflow uses OpenID Connect (OIDC) for secure authentication with AWS. This requires:

1. Proper IAM role configuration:

   - Trust relationship with GitHub OIDC provider
   - Correct repository name in the trust policy
   - Necessary permissions for ECR, SSM, and Secrets Manager

2. GitHub Actions permissions:
   - `id-token: write` permission in the workflow
   - Correct role ARN in the workflow configuration

### 4. ECR Repository

The Docker images are pushed to:

```
255945442255.dkr.ecr.us-east-1.amazonaws.com/azni-flask-private-repository
```

### 5. ECS Task Definition

The `task-definition.json` file defines the ECS task configuration:

- Uses Fargate launch type
- References SSM Parameter for database URL
- References Secrets Manager for credentials
- Configures logging to CloudWatch
- Uses awsvpc network mode

#### Parameter and Secret References

The task definition references parameters and secrets as follows:

1. SSM Parameter:

```json
"environment": [
    {
        "name": "DB_URL",
        "value": "{{resolve:ssm:/azni/config}}"
    }
]
```

2. Secrets Manager:

```json
"secrets": [
    {
        "name": "DB_USERNAME",
        "valueFrom": "arn:aws:secretsmanager:us-east-1:255945442255:secret:azni/db_password:username::"
    },
    {
        "name": "DB_PASSWORD",
        "valueFrom": "arn:aws:secretsmanager:us-east-1:255945442255:secret:azni/db_password:password::"
    }
]
```

## Local Development

1. Install dependencies:

```bash
pip install -r requirements.txt
```

2. Run the Flask application:

```bash
python app.py
```

3. Build the Docker image locally:

```bash
docker build -t azni-flask-app .
```

4. Run the container:

```bash
docker run -p 5000:5000 azni-flask-app
```

## Security Considerations

- The GitHub Actions workflow uses OIDC for secure authentication
- IAM role has minimal required permissions
- Images are tagged with both `latest` and commit SHA for traceability
- Sensitive data is stored in SSM Parameter Store and Secrets Manager
- Database credentials are securely managed and rotated
- ECS task definition uses secure parameter resolution
- All secrets and parameters are encrypted at rest
- Access is controlled through IAM policies

## Troubleshooting

### Parameter and Secret Access Issues

If you encounter issues accessing parameters or secrets:

1. Verify IAM permissions:

```bash
aws iam get-role-policy --role-name ecsTaskExecutionRole --policy-name SSMSecretsAccess
```

2. Check parameter existence:

```bash
aws ssm get-parameter --name "/azni/config" --with-decryption
```

3. Verify secret access:

```bash
aws secretsmanager get-secret-value --secret-id "azni/db_password"
```

4. Check task execution role:

```bash
aws iam get-role --role-name ecsTaskExecutionRole
```

### OIDC Authentication Issues

If you encounter the error "Not authorized to perform sts:AssumeRoleWithWebIdentity":

1. Verify the IAM role configuration:

```bash
aws iam get-role --role-name github-actions-role
```

2. Check the trust policy:

```bash
aws iam get-role --role-name github-actions-role --query 'Role.AssumeRolePolicyDocument'
```

3. Ensure the GitHub repository name matches exactly in:

   - The trust policy
   - The workflow file
   - The actual repository

4. Verify the OIDC provider:

```bash
aws iam list-open-id-connect-providers
```

5. Check GitHub Actions permissions:
   - Ensure `id-token: write` is set in the workflow
   - Verify the role ARN is correct

### General Issues

1. Verify the IAM role ARN in the workflow file
2. Check that the OIDC provider is properly configured
3. Ensure the ECR repository exists and is accessible
4. Verify SSM Parameter and Secrets Manager resources
5. Check ECS task execution role permissions
6. Review GitHub Actions logs for detailed error messages

## License

This project is licensed under the MIT License - see the LICENSE file for details.
