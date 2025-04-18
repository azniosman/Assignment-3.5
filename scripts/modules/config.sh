#!/bin/bash

# AWS Configuration
export AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-"255945442255"}
export AWS_REGION=${AWS_REGION:-"us-east-1"}
export REPO_NAME=${REPO_NAME:-"azni-flask-xray-repo"}
export GITHUB_REPO=${GITHUB_REPO:-"azniosman/Assignment-3.5"}

# Script Configuration
# SCRIPT_DIR and PROJECT_ROOT are defined in setup-aws.sh
export TASK_DEFINITION_FILE="${PROJECT_ROOT}/task-definition.json"

# Security Configuration
export VPC_CIDR="10.0.0.0/16"
export SUBNET_CIDR="10.0.1.0/24"
export ALLOWED_IP_RANGES="0.0.0.0/0"
export CONTAINER_PORT=8080
export MIN_TASK_COUNT=1
export MAX_TASK_COUNT=2
export DESIRED_TASK_COUNT=1
export CPU_UNITS=256
export MEMORY_MB=512

# Resource Names
export VPC_NAME="azni-flask-vpc"
export IGW_NAME="azni-flask-igw"
export SUBNET_NAME="azni-flask-subnet"
export SG_NAME="azni-flask-sg"
export RT_NAME="azni-flask-rt"
export CLUSTER_NAME="azni-flask-xray-cluster"
export SERVICE_NAME="azni-flask-service"
export SSM_PARAMETER_NAME="/azni/config"
export SECRET_NAME="azni/db_password"

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export NC='\033[0m' # No Color