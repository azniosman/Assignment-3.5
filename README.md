# Container Orchestration with ECS

This project demonstrates a Flask application containerized with Docker and deployed using AWS ECS with GitHub Actions for CI/CD.

## Project Structure

```
.
├── .github/workflows/docker-push.yml  # GitHub Actions workflow
├── scripts/setup-aws.sh               # AWS setup script
├── app.py                             # Flask application
├── Dockerfile                         # Docker configuration
├── requirements.txt                   # Python dependencies
├── task-definition.json              # ECS Task Definition
└── README.md                         # Documentation
```

## Prerequisites

- AWS Account with appropriate permissions
- AWS CLI configured with credentials
- Docker installed locally
- GitHub repository access

## Quick Start

### 1. AWS Setup

```bash
chmod +x scripts/setup-aws.sh
./scripts/setup-aws.sh
```

The script provides a menu to set up or delete:

- OIDC Provider for GitHub Actions
- IAM Roles
- VPC Resources
- ECS Cluster and Service
- SSM Parameters and Secrets

### 2. Local Development

```bash
# Install dependencies
pip install -r requirements.txt

# Run locally
python app.py

# Build and run Docker container
docker build -t azni-flask-app .
docker run -p 5000:5000 azni-flask-app
```

## AWS Resources

- **ECS Cluster**: `azni-flask-xray-cluster`
- **ECS Service**: `azni-flask-service`
- **Task Definition**: `azni-flask-task`
- **SSM Parameter**: `/azni/config`
- **Secret**: `azni/db_password`
- **Log Group**: `/ecs/azni-flask`

## Common Commands

### ECS Management

```bash
# Check cluster status
aws ecs describe-clusters --clusters azni-flask-xray-cluster

# List services
aws ecs list-services --cluster azni-flask-xray-cluster

# List tasks
aws ecs list-tasks --cluster azni-flask-xray-cluster
```

### Parameter and Secret Management

```bash
# View parameter
aws ssm get-parameter --name "/azni/config" --with-decryption

# View secret
aws secretsmanager get-secret-value --secret-id "azni/db_password"
```

## Troubleshooting

### CloudWatch Logs

```bash
aws logs get-log-events --log-group-name /ecs/azni-flask --log-stream-name ecs/flask-app/task-id
```

### Service Events

```bash
aws ecs describe-services --cluster azni-flask-xray-cluster --services azni-flask-service --query 'services[0].events'
```

## Security Features

- OIDC authentication for GitHub Actions
- Secure parameter and secret management
- Minimal IAM permissions
- Encrypted secrets and parameters

## License

This project is licensed under the MIT License.
