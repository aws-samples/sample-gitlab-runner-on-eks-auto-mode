#!/bin/bash
set -e

# Source common functions
source "$(dirname "$0")/common-functions.sh"

# Verify if user has aws access
check_aws_credentials || exit 1

# Read values from defaults.json and custom.json
DEFAULTS_CONFIG="../configs/defaults.json"
CUSTOM_CONFIG="../configs/custom.json"

# Validate defaults.json (required)
load_config "$DEFAULTS_CONFIG" true || exit 1
load_config "$CUSTOM_CONFIG" true || exit 1

# Merge configurations
MERGED_CONFIG=$(merge_configs "$DEFAULTS_CONFIG" "$CUSTOM_CONFIG")

# AWS configurations
AWS_REGION=$(echo "$MERGED_CONFIG" | jq -r '.aws.region')
export AWS_REGION

# EKS configurations
CLUSTER_NAME=$(echo "$MERGED_CONFIG" | jq -r '.eks.cluster_name')
EKS_VERSION=$(echo "$MERGED_CONFIG" | jq -r '.eks.version')

# IAM configurations
IAM_ROLE_NAME=$(echo "$MERGED_CONFIG" | jq -r '.iam.role_name')
IAM_MANAGED_POLICY_LIST=$(echo "$MERGED_CONFIG" | jq -r '.iam.aws_managed_policy_list[]')

# GitLab configurations
GITLAB_NAMESPACE=$(echo "$MERGED_CONFIG" | jq -r '.gitlab.namespace')
GITLAB_SERVICE_ACCOUNT=$(echo "$MERGED_CONFIG" | jq -r '.gitlab.service_account')
GITLAB_URL=$(echo "$MERGED_CONFIG" | jq -r '.gitlab.url')
GITLAB_RUNNER_TOKEN=$(echo "$MERGED_CONFIG" | jq -r '.gitlab.runner_token')
GITLAB_CHART_VERSION=$(echo "$MERGED_CONFIG" | jq -r '.gitlab.chart_version // "0.55.0"')


eksctl upgrade cluster -f ../configs/generated/gitlab-eks-cluster.yaml

kubectl apply -f ../k8s-chart/gitlab-instance-node-pool.yaml

# Add and update GitLab Helm repository
echo "Updating GitLab Helm repository..."
helm repo update

helm upgrade --install gitlab-runner -f ../configs/generated/gitlab-runner-values-generated.yaml gitlab/gitlab-runner \
  --version ${GITLAB_CHART_VERSION} \
  -n $GITLAB_NAMESPACE