#!/bin/bash

# AWS Target Group Copy Script
# Usage: ./copy_target_group.sh <source-tg-name> <new-tg-name> [vpc-id]

set -e

# Record start time
START_TIME=$(date +%s)

# Function to send notification
send_notification() {
    local message="$1"
    local status="$2"
    
    if [[ -n "$NTFY_TOPIC" ]]; then
        local emoji="✅"
        local priority="default"
        
        if [[ "$status" == "error" ]]; then
            emoji="❌"
            priority="high"
        fi
        
        # Check if curl is available, otherwise use wget
        if command -v curl >/dev/null 2>&1; then
            curl -s -d "$emoji AWS TG Copy: $message" \
                -H "Priority: $priority" \
                "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true
        elif command -v wget >/dev/null 2>&1; then
            wget -q --post-data="$emoji AWS TG Copy: $message" \
                --header="Priority: $priority" \
                "https://ntfy.sh/$NTFY_TOPIC" -O /dev/null 2>&1 || true
        fi
    fi
}

# Function to calculate and display elapsed time
show_elapsed_time() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))
    
    if [[ $hours -gt 0 ]]; then
        echo "Time elapsed: ${hours}h ${minutes}m ${seconds}s"
    elif [[ $minutes -gt 0 ]]; then
        echo "Time elapsed: ${minutes}m ${seconds}s"
    else
        echo "Time elapsed: ${seconds}s"
    fi
}

# Function to handle script exit
cleanup() {
    local exit_code=$?
    show_elapsed_time
    
    if [[ $exit_code -eq 0 ]]; then
        local elapsed_msg=$(show_elapsed_time)
        send_notification "Target group copied successfully. $elapsed_msg" "success"
    else
        local elapsed_msg=$(show_elapsed_time)
        send_notification "Target group copy failed. $elapsed_msg" "error"
    fi
}

# Set up trap for cleanup
trap cleanup EXIT

# Check if AWS CLI is installed
if ! command -v aws >/dev/null 2>&1; then
    echo "Error: AWS CLI is not installed or not in PATH"
    exit 1
fi

# Check parameters
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <source-target-group-name> <new-target-group-name> [vpc-id]"
    echo "Example: $0 my-old-tg my-new-tg vpc-12345678"
    exit 1
fi

SOURCE_TG_NAME="$1"
NEW_TG_NAME="$2"
VPC_ID="$3"

echo "Starting AWS Target Group copy process..."
echo "Source Target Group: $SOURCE_TG_NAME"
echo "New Target Group: $NEW_TG_NAME"

# Get source target group details
echo "Fetching source target group details..."
SOURCE_TG_ARN=$(aws elbv2 describe-target-groups \
    --names "$SOURCE_TG_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null) || {
    echo "Error: Could not find target group '$SOURCE_TG_NAME'"
    exit 1
}

if [[ "$SOURCE_TG_ARN" == "None" || -z "$SOURCE_TG_ARN" ]]; then
    echo "Error: Target group '$SOURCE_TG_NAME' not found"
    exit 1
fi

# Get target group configuration
echo "Retrieving target group configuration..."
TG_CONFIG=$(aws elbv2 describe-target-groups --target-group-arns "$SOURCE_TG_ARN" --output json)

# Extract configuration details
PROTOCOL=$(echo "$TG_CONFIG" | jq -r '.TargetGroups[0].Protocol')
PORT=$(echo "$TG_CONFIG" | jq -r '.TargetGroups[0].Port')
TG_VPC_ID=$(echo "$TG_CONFIG" | jq -r '.TargetGroups[0].VpcId')
TARGET_TYPE=$(echo "$TG_CONFIG" | jq -r '.TargetGroups[0].TargetType')
HEALTH_CHECK_PROTOCOL=$(echo "$TG_CONFIG" | jq -r '.TargetGroups[0].HealthCheckProtocol')
HEALTH_CHECK_PATH=$(echo "$TG_CONFIG" | jq -r '.TargetGroups[0].HealthCheckPath')
HEALTH_CHECK_PORT=$(echo "$TG_CONFIG" | jq -r '.TargetGroups[0].HealthCheckPort')
HEALTH_CHECK_INTERVAL=$(echo "$TG_CONFIG" | jq -r '.TargetGroups[0].HealthCheckIntervalSeconds')
HEALTH_CHECK_TIMEOUT=$(echo "$TG_CONFIG" | jq -r '.TargetGroups[0].HealthCheckTimeoutSeconds')
HEALTHY_THRESHOLD=$(echo "$TG_CONFIG" | jq -r '.TargetGroups[0].HealthyThresholdCount')
UNHEALTHY_THRESHOLD=$(echo "$TG_CONFIG" | jq -r '.TargetGroups[0].UnhealthyThresholdCount')

# Use provided VPC ID or use the same as source
FINAL_VPC_ID=${VPC_ID:-$TG_VPC_ID}

echo "Configuration retrieved:"
echo "  Protocol: $PROTOCOL"
echo "  Port: $PORT"
echo "  VPC ID: $FINAL_VPC_ID"
echo "  Target Type: $TARGET_TYPE"

# Create new target group
echo "Creating new target group '$NEW_TG_NAME'..."
CREATE_CMD="aws elbv2 create-target-group \
    --name '$NEW_TG_NAME' \
    --protocol '$PROTOCOL' \
    --port $PORT \
    --vpc-id '$FINAL_VPC_ID' \
    --target-type '$TARGET_TYPE'"

# Add health check parameters
if [[ "$HEALTH_CHECK_PATH" != "null" && "$HEALTH_CHECK_PATH" != "" ]]; then
    CREATE_CMD="$CREATE_CMD --health-check-path '$HEALTH_CHECK_PATH'"
fi

CREATE_CMD="$CREATE_CMD \
    --health-check-protocol '$HEALTH_CHECK_PROTOCOL' \
    --health-check-port '$HEALTH_CHECK_PORT' \
    --health-check-interval-seconds $HEALTH_CHECK_INTERVAL \
    --health-check-timeout-seconds $HEALTH_CHECK_TIMEOUT \
    --healthy-threshold-count $HEALTHY_THRESHOLD \
    --unhealthy-threshold-count $UNHEALTHY_THRESHOLD"

# Execute the create command
NEW_TG_ARN=$(eval "$CREATE_CMD" --query 'TargetGroups[0].TargetGroupArn' --output text)

if [[ -z "$NEW_TG_ARN" || "$NEW_TG_ARN" == "None" ]]; then
    echo "Error: Failed to create new target group"
    exit 1
fi

echo "New target group created with ARN: $NEW_TG_ARN"

# Copy target group attributes
echo "Copying target group attributes..."
ATTRIBUTES=$(aws elbv2 describe-target-group-attributes \
    --target-group-arn "$SOURCE_TG_ARN" \
    --query 'Attributes[?Key!=`load_balancing.cross_zone.enabled`]' \
    --output json)

if [[ "$ATTRIBUTES" != "[]" && "$ATTRIBUTES" != "null" ]]; then
    aws elbv2 modify-target-group-attributes \
        --target-group-arn "$NEW_TG_ARN" \
        --attributes "$ATTRIBUTES" >/dev/null
    echo "Target group attributes copied"
fi

# Copy tags
echo "Copying tags..."
TAGS=$(aws elbv2 describe-tags \
    --resource-arns "$SOURCE_TG_ARN" \
    --query 'TagDescriptions[0].Tags' \
    --output json)

if [[ "$TAGS" != "[]" && "$TAGS" != "null" ]]; then
    aws elbv2 add-tags \
        --resource-arns "$NEW_TG_ARN" \
        --tags "$TAGS" >/dev/null
    echo "Tags copied"
fi

# Copy registered targets
echo "Copying registered targets..."
TARGETS=$(aws elbv2 describe-target-health \
    --target-group-arn "$SOURCE_TG_ARN" \
    --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy` || TargetHealth.State==`unhealthy` || TargetHealth.State==`initial`].Target' \
    --output json)

if [[ "$TARGETS" != "[]" && "$TARGETS" != "null" ]]; then
    aws elbv2 register-targets \
        --target-group-arn "$NEW_TG_ARN" \
        --targets "$TARGETS" >/dev/null
    
    TARGET_COUNT=$(echo "$TARGETS" | jq length)
    echo "Registered $TARGET_COUNT targets"
else
    echo "No targets to copy"
fi

echo ""
echo "✅ Target group copy completed successfully!"
echo "Source: $SOURCE_TG_NAME ($SOURCE_TG_ARN)"
echo "New: $NEW_TG_NAME ($NEW_TG_ARN)"
echo ""
echo "Note: Remember to:"
echo "1. Update any load balancer listeners to use the new target group"
echo "2. Verify that all targets are healthy in the new target group"
echo "3. Delete the old target group when no longer needed"