# Container Orchestration with ECS

This project demonstrates a Flask application containerized with Docker and deployed using AWS ECS. The repository includes GitHub Actions workflow for automated builds and deployments to Amazon ECR.

## Project Structure

```
.
├── .github/
│   └── workflows/
│       └── docker-push.yml    # GitHub Actions workflow
├── scripts/
│   └── setup-aws.sh          # AWS setup script (OIDC & IAM)
├── app.py                     # Flask application
├── Dockerfile                 # Docker configuration
├── requirements.txt           # Python dependencies
└── README.md                 # Project documentation
```

## Prerequisites

- AWS Account with appropriate permissions
- AWS CLI configured with credentials
- Docker installed locally
- GitHub repository access

## Setup Instructions

### 1. AWS Setup

The repository includes a menu-driven setup script in the `scripts` directory that handles both OIDC provider and IAM role configuration:

```bash
# Make the script executable
chmod +x scripts/setup-aws.sh

# Run the setup script
./scripts/setup-aws.sh
```

The script provides the following options:

1. Setup OIDC Provider
2. Setup IAM Role
3. Setup Both (OIDC Provider and IAM Role)
4. Exit

The script includes:

- Error handling and validation
- AWS CLI and credentials checks
- Color-coded output for better visibility
- Automatic cleanup of temporary files

### 2. GitHub Actions Workflow

The repository includes a GitHub Actions workflow (`.github/workflows/docker-push.yml`) that:

- Triggers on pushes to the main branch
- Builds the Docker image
- Tags the image with both `latest` and the commit SHA
- Pushes the image to ECR

The workflow uses OIDC (OpenID Connect) for secure authentication with AWS.

### 3. ECR Repository

The Docker images are pushed to:

```
255945442255.dkr.ecr.us-east-1.amazonaws.com/azni-flask-private-repository
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

## Troubleshooting

If you encounter issues with the GitHub Actions workflow:

1. Verify the IAM role ARN in the workflow file
2. Check that the OIDC provider is properly configured
3. Ensure the ECR repository exists and is accessible
4. Review GitHub Actions logs for detailed error messages

## License

This project is licensed under the MIT License - see the LICENSE file for details.
# Assignment-3.5
