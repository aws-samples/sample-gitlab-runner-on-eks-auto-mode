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

# Check if custom.json exists
if [ -f "$CUSTOM_CONFIG" ]; then
  load_config "$CUSTOM_CONFIG" false
  # Merge configurations
  MERGED_CONFIG=$(merge_configs "$DEFAULTS_CONFIG" "$CUSTOM_CONFIG")
else
  echo "Custom configuration file not found, using defaults only."
  MERGED_CONFIG=$(cat "$DEFAULTS_CONFIG")
fi

# AWS configurations
AWS_REGION=$(echo "$MERGED_CONFIG" | jq -r '.aws.region')
export AWS_REGION

# EKS configurations
CLUSTER_NAME=$(echo "$MERGED_CONFIG" | jq -r '.eks.cluster_name')

# IAM configurations
IAM_ROLE_NAME=$(echo "$MERGED_CONFIG" | jq -r '.iam.role_name')


echo "Starting cleanup process..."
echo "- AWS Region: $AWS_REGION"
echo "- Cluster Name: $CLUSTER_NAME"
echo "- IAM Role: $IAM_ROLE_NAME"



# Get OIDC provider URL
echo "Getting OIDC provider URL..."
OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text 2>/dev/null || echo "")
if [ -n "$OIDC_URL" ]; then
  OIDC_PROVIDER=$(echo $OIDC_URL | sed -e "s/^https:\/\///")
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  
  # Delete IAM OIDC provider
  echo "Deleting IAM OIDC provider..."
  PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $PROVIDER_ARN || echo "OIDC provider not found or already deleted"
fi

# Delete EKS cluster
echo "Deleting EKS cluster..."
eksctl delete cluster --name $CLUSTER_NAME --wait || echo "Cluster already deleted or doesn't exist"

# Delete IAM role policies
echo "Detaching IAM policies from role..."
ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name $IAM_ROLE_NAME --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null || echo "")
if [ -n "$ATTACHED_POLICIES" ]; then
  for POLICY_ARN in $ATTACHED_POLICIES; do
    echo "Detaching policy: $POLICY_ARN"
    aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn $POLICY_ARN || echo "Failed to detach policy: $POLICY_ARN"
  done
fi

# Delete IAM role
echo "Deleting IAM role..."
aws iam delete-role --role-name $IAM_ROLE_NAME || echo "Role already deleted"

echo "Cleanup completed successfully!"