#!/bin/bash
set -e

# If configs exists, ask to clean them up or cancel this new installation.
if [ -d "../configs/generated" ]; then
  echo "Configs directory already exists. Do you want to clean up and start a new installation? (y/n)"
  read -r answer
  if [ "$answer" != "y" ]; then
    echo "Exiting..."
    exit 1
  fi
  echo "Cleaning up configs directory..."
  rm -rf ../configs/generated
  mkdir -p ../configs/generated
fi



# Source common functions
source "$(dirname "$0")/common-functions.sh"

# Verify if user has aws access
check_aws_credentials || exit 1

# Read values from defaults.json and custom.json
DEFAULTS_CONFIG="../configs/defaults.json"
CUSTOM_CONFIG="../configs/custom.json"

# Validate defaults.json (required)
load_config "$DEFAULTS_CONFIG" true || exit 1

# Check if custom.json exists, create it if not
if [ ! -f "$CUSTOM_CONFIG" ]; then
  echo "Custom configuration file not found. Let's create one."
  create_custom_config "$CUSTOM_CONFIG" || exit 1
else
  # Validate custom.json if it exists
  load_config "$CUSTOM_CONFIG" true || exit 1
fi

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

# GitLab configurations
GITLAB_NAMESPACE=$(echo "$MERGED_CONFIG" | jq -r '.gitlab.namespace')
GITLAB_SERVICE_ACCOUNT=$(echo "$MERGED_CONFIG" | jq -r '.gitlab.service_account')
GITLAB_URL=$(echo "$MERGED_CONFIG" | jq -r '.gitlab.url')
GITLAB_RUNNER_TOKEN=$(echo "$MERGED_CONFIG" | jq -r '.gitlab.runner_token')
GITLAB_CHART_VERSION=$(echo "$MERGED_CONFIG" | jq -r '.gitlab.chart_version // "0.55.0"')

echo "Using configuration:"
echo "- AWS Region: $AWS_REGION"
echo "- Cluster Name: $CLUSTER_NAME"
echo "- EKS Version: $EKS_VERSION"
echo "- GitLab Namespace: $GITLAB_NAMESPACE"
echo "- GitLab Service Account: $GITLAB_SERVICE_ACCOUNT"





mkdir -p ../configs/generated

# Create EKS cluster config file
echo "Creating EKS cluster config file..."
cat > ../configs/generated/gitlab-eks-cluster.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $CLUSTER_NAME
  region: $AWS_REGION
  version: "$EKS_VERSION"
  # Optional but recommended tags
  tags:
    Environment: Production

addons:
  - name: eks-pod-identity-agent
  
# Disable default networking add-ons as EKS Auto Mode 
# comes integrated with VPC CNI, kube-proxy, and CoreDNS
addonsConfig:
  disableDefaultAddons: true

iam:
  withOIDC: true

# Enable Auto Mode configuration
autoModeConfig:
  enabled: true
  # Using default nodePools which includes general-purpose and system
  nodePools: [ general-purpose, system ]
EOF



# Create the EKS cluster
echo "Creating EKS cluster..."
eksctl create cluster -f ../configs/generated/gitlab-eks-cluster.yaml

# Add karpenter spot instance pool
echo "Adding karpenter instance pool..."
kubectl apply -f ../k8s-chart/gitlab-instance-node-pool.yaml


# Get the OIDC provider URL
echo "Getting OIDC provider URL..."
OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text)
OIDC_PROVIDER=$(echo $OIDC_URL | sed -e "s/^https:\/\///")
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "OIDC Provider URL: $OIDC_URL"
echo "OIDC Provider: $OIDC_PROVIDER"
echo "AWS Account ID: $AWS_ACCOUNT_ID"

# Create IAM OIDC identity provider
echo "Creating IAM OIDC identity provider..."
aws iam list-open-id-connect-providers | grep $OIDC_PROVIDER || aws iam create-open-id-connect-provider \
  --url $OIDC_URL \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list $(echo | openssl s_client -servername oidc.eks.$AWS_REGION.amazonaws.com -showcerts -connect oidc.eks.$AWS_REGION.amazonaws.com:443 2>&- | tac | sed -n '/-----END CERTIFICATE-----/,/-----BEGIN CERTIFICATE-----/p; /-----BEGIN CERTIFICATE-----/q' | tac | openssl x509 -fingerprint -noout | sed 's/://g' | awk -F= '{print tolower($2)}')

# Create trust policy for the IAM role
echo "Creating trust policy..."
cat > ../configs/generated/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${GITLAB_NAMESPACE}:${GITLAB_SERVICE_ACCOUNT}"
        }
      }
    }
  ]
}
EOF


# Create IAM role
echo "Creating IAM role..."
aws iam create-role --role-name $IAM_ROLE_NAME --assume-role-policy-document file://../configs/generated/trust-policy.json



# Create temporary service account file with AWS account ID
echo "Creating ServiceAccount manifest with AWS account ID..."
cat > ../configs/generated/gitlab-serviceaccount.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${GITLAB_SERVICE_ACCOUNT}
  namespace: ${GITLAB_NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}"
EOF

# Create the gitlab namespace if it doesn't exist
echo "Creating gitlab namespace..."
kubectl get namespace $GITLAB_NAMESPACE || kubectl create namespace $GITLAB_NAMESPACE

# Apply the ServiceAccount
echo "Applying ServiceAccount..."
kubectl apply -f ../configs/generated/gitlab-serviceaccount.yaml



# Create temporary values file for Helm
echo "Creating GitLab Runner values file..."
# Create the values file

cat > ../configs/generated/gitlab-runner-values-generated.yaml << EOF
# Generated from merged defaults.json and custom.json
# Based on the Gitlab runner helm chart.
# REF: https://gitlab.com/gitlab-org/charts/gitlab-runner/-/tree/main
# Values REF: https://gitlab.com/gitlab-org/charts/gitlab-runner/-/blob/main/values.yaml
gitlabUrl: ${GITLAB_URL}
runnerToken: "${GITLAB_RUNNER_TOKEN}"
concurrent: $(echo "$MERGED_CONFIG" | jq -r '.gitlab.concurrent_jobs')

rbac:
  create: true
  clusterWideAccess: false
  
serviceAccount:
  create: false
  name: "${GITLAB_SERVICE_ACCOUNT}"

resources:
  limits:
    memory: "$(echo "$MERGED_CONFIG" | jq -r '.gitlab.resources.limits.memory')"
    cpu: "$(echo "$MERGED_CONFIG" | jq -r '.gitlab.resources.limits.cpu')"
    ephemeral-storage: "$(echo "$MERGED_CONFIG" | jq -r '.gitlab.resources.limits.ephemeral_storage')"
  requests:
    memory: "$(echo "$MERGED_CONFIG" | jq -r '.gitlab.resources.requests.memory')"
    cpu: "$(echo "$MERGED_CONFIG" | jq -r '.gitlab.resources.requests.cpu')"
    ephemeral-storage: "$(echo "$MERGED_CONFIG" | jq -r '.gitlab.resources.requests.ephemeral_storage')"

nodeSelector: 
  karpenter.sh/nodepool: "gitlab-main"


# Add health checks based on configuration
livenessProbe:
  initialDelaySeconds: $(echo "$MERGED_CONFIG" | jq -r '.gitlab.health_check.livenessProbe.initialDelaySeconds // 60')
  periodSeconds: $(echo "$MERGED_CONFIG" | jq -r '.gitlab.health_check.livenessProbe.periodSeconds // 10')
  timeoutSeconds: $(echo "$MERGED_CONFIG" | jq -r '.gitlab.health_check.livenessProbe.timeoutSeconds // 3')
  successThreshold: $(echo "$MERGED_CONFIG" | jq -r '.gitlab.health_check.livenessProbe.successThreshold // 1')
  failureThreshold: $(echo "$MERGED_CONFIG" | jq -r '.gitlab.health_check.livenessProbe.failureThreshold // 3')

readinessProbe:
  initialDelaySeconds: $(echo "$MERGED_CONFIG" | jq -r '.gitlab.health_check.readinessProbe.initialDelaySeconds // 10')
  periodSeconds: $(echo "$MERGED_CONFIG" | jq -r '.gitlab.health_check.readinessProbe.periodSeconds // 10')
  timeoutSeconds: $(echo "$MERGED_CONFIG" | jq -r '.gitlab.health_check.readinessProbe.timeoutSeconds // 3')
  successThreshold: $(echo "$MERGED_CONFIG" | jq -r '.gitlab.health_check.readinessProbe.successThreshold // 1')
  failureThreshold: $(echo "$MERGED_CONFIG" | jq -r '.gitlab.health_check.readinessProbe.failureThreshold // 3')
    
runners:
  config: |
    [[runners]]
      [runners.kubernetes]
        namespace = "${GITLAB_NAMESPACE}"
        image = "alpine:latest"
        service_account = "${GITLAB_SERVICE_ACCOUNT}"
        [runners.kubernetes.node_selector]
          "karpenter.sh/nodepool" = "gitlab-spot"

EOF

echo "GitLab Runner values file generated at gitlab-runner-values-generated.yaml"

# Add and update GitLab Helm repository
echo "Adding GitLab Helm repository..."
helm repo list | grep -q "^gitlab" || helm repo add gitlab https://charts.gitlab.io/
helm repo update

# Install or upgrade GitLab Runner with Helm
echo "Installing/upgrading GitLab Runner..."
helm upgrade --install gitlab-runner -f ../configs/generated/gitlab-runner-values-generated.yaml gitlab/gitlab-runner \
  --version ${GITLAB_CHART_VERSION} \
  -n $GITLAB_NAMESPACE


echo "GitLab Runner installation complete!"

echo "Waiting for gitlab runner to come up"
while ! kubectl get pods -n $GITLAB_NAMESPACE | grep -q "1/1"; do
  echo "Waiting for gitlab runner to come up..."
  sleep 5
done
echo "Gitlab runner is up and running!"
kubectl get all -n gitlab


echo "---------------------------"
echo "Installation complete!"
echo "---------------------------"
# provide the instructions to the user to attach their policy to the IAM Role.
echo "Before you start using the runner, please attach a policy to the IAM Role: $IAM_ROLE_NAME"
