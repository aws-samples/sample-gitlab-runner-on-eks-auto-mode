#!/bin/bash
# Common functions for GitLab EKS deployment scripts

# Merge JSON from defaults and custom configs
merge_configs() {
  local DEFAULTS_CONFIG=$1
  local CUSTOM_CONFIG=$2
  jq -s '.[0] * .[1]' "$DEFAULTS_CONFIG" "$CUSTOM_CONFIG"
}

# Get AWS account ID
get_aws_account_id() {
  aws sts get-caller-identity --query Account --output text
}

# Validate if AWS credentials are configured
check_aws_credentials() {
  if ! aws sts get-caller-identity &>/dev/null; then
    echo "AWS credentials not found. Please run 'aws configure' to set up your AWS credentials."
    return 1
  fi
  return 0
}

# Load configuration from JSON file
load_config() {
  local CONFIG_FILE=$1
  local REQUIRED=$2
  
  if [ ! -f "$CONFIG_FILE" ]; then
    if [ "$REQUIRED" = "true" ]; then
      echo "Config file not found: $CONFIG_FILE"
      return 1
    else
      echo "Config file not found: $CONFIG_FILE, but it's optional"
      return 0
    fi
  fi
  
  # Validate JSON syntax
  if ! jq -e . "$CONFIG_FILE" > /dev/null 2>&1; then
    echo "Invalid JSON in config file: $CONFIG_FILE"
    return 1
  fi
  
  echo "Configuration loaded from $CONFIG_FILE"
  return 0
}

# Create custom config file with required parameters
create_custom_config() {
  local CONFIG_FILE=$1
  local CONFIG_DIR=$(dirname "$CONFIG_FILE")
  
  # Create directory if it doesn't exist
  mkdir -p "$CONFIG_DIR"
  
  echo "Creating custom configuration file at $CONFIG_FILE"
  
  # Ask for GitLab runner token
  read -p "Enter your GitLab runner registration token: " RUNNER_TOKEN
  
  # Ask for AWS managed policies as CSV
  read -p "Enter comma-separated list of AWS managed policies (default: ReadOnlyAccess): " MANAGED_POLICIES
  MANAGED_POLICIES=${MANAGED_POLICIES:-ReadOnlyAccess}
  
  # Convert CSV to JSON array
  POLICIES_JSON=$(echo "$MANAGED_POLICIES" | sed 's/,/","/g' | sed 's/^/["/' | sed 's/$/"]/')
  
  # Create the custom config file
  cat > "$CONFIG_FILE" << EOF
{
  "iam": {
    "aws_managed_policy_list": ${POLICIES_JSON}
  },
  "gitlab": {
    "runner_token": "${RUNNER_TOKEN}"
  }
}
EOF
  
  echo "Custom configuration file created successfully"
  return 0
}