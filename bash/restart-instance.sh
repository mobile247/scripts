#!/bin/bash

# EC2 Instance Stop/Start Script
# Usage: ./ec2_restart.sh <instance-name>

set -e

# Start timing
START_TIME=$(date +%s)

# Function to send notification if NTFY_TOPIC is set
send_notification() {
    local message="$1"
    local title="$2"
    
    if [[ -n "${NTFY_TOPIC}" ]]; then
        # Check if curl is available, otherwise use wget
        if command -v curl &> /dev/null; then
            curl -H "Title: ${title}" -d "${message}" "ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
        elif command -v wget &> /dev/null; then
            wget -qO- --header="Title: ${title}" --post-data="${message}" "ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
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
        echo "Total execution time: ${hours}h ${minutes}m ${seconds}s"
    elif [[ $minutes -gt 0 ]]; then
        echo "Total execution time: ${minutes}m ${seconds}s"
    else
        echo "Total execution time: ${seconds}s"
    fi
}

# Function to cleanup and exit
cleanup_and_exit() {
    local exit_code=$1
    local message="$2"
    show_elapsed_time
    
    if [[ $exit_code -eq 0 ]]; then
        send_notification "✅ EC2 restart completed successfully. ${message}" "EC2 Script Success"
    else
        send_notification "❌ EC2 restart failed. ${message}" "EC2 Script Failed"
    fi
    
    exit $exit_code
}

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed or not in PATH"
    cleanup_and_exit 1 "AWS CLI not found"
fi

# Check if instance name is provided
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <instance-name>"
    echo "Example: $0 my-web-server"
    cleanup_and_exit 1 "No instance name provided"
fi

INSTANCE_NAME="$1"
STOP_TIMEOUT=300  # 5 minutes timeout for stopping

echo "Searching for EC2 instances with name: ${INSTANCE_NAME}"

# Find instances matching the name
INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],PrivateIpAddress,State.Name]' \
    --output text 2>/dev/null)

if [[ -z "$INSTANCES" ]]; then
    echo "No instances found with name: ${INSTANCE_NAME}"
    cleanup_and_exit 1 "No instances found"
fi

# Count number of instances
INSTANCE_COUNT=$(echo "$INSTANCES" | wc -l)

if [[ $INSTANCE_COUNT -eq 1 ]]; then
    # Single instance found
    read -r INSTANCE_ID INSTANCE_NAME_TAG PRIVATE_IP STATE <<< "$INSTANCES"
    echo "Found instance: $INSTANCE_ID ($INSTANCE_NAME_TAG) - $PRIVATE_IP [$STATE]"
    SELECTED_INSTANCE_ID="$INSTANCE_ID"
else
    # Multiple instances found - let user choose
    echo "Found $INSTANCE_COUNT instances matching '$INSTANCE_NAME':"
    echo ""
    echo "Index | Instance ID          | Name                 | Private IP      | State"
    echo "------|---------------------|---------------------|-----------------|----------"
    
    declare -a INSTANCE_IDS
    declare -a INSTANCE_DETAILS
    INDEX=1
    
    while IFS=$'\t' read -r INSTANCE_ID INSTANCE_NAME_TAG PRIVATE_IP STATE; do
        printf "%-5s | %-19s | %-19s | %-15s | %s\n" "$INDEX" "$INSTANCE_ID" "$INSTANCE_NAME_TAG" "$PRIVATE_IP" "$STATE"
        INSTANCE_IDS[$INDEX]="$INSTANCE_ID"
        INSTANCE_DETAILS[$INDEX]="$INSTANCE_NAME_TAG ($INSTANCE_ID) - $PRIVATE_IP [$STATE]"
        ((INDEX++))
    done <<< "$INSTANCES"
    
    echo ""
    read -p "Select instance index (1-$INSTANCE_COUNT): " SELECTION
    
    # Validate selection
    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [[ $SELECTION -lt 1 ]] || [[ $SELECTION -gt $INSTANCE_COUNT ]]; then
        echo "Invalid selection: $SELECTION"
        cleanup_and_exit 1 "Invalid instance selection"
    fi
    
    SELECTED_INSTANCE_ID="${INSTANCE_IDS[$SELECTION]}"
    echo "Selected: ${INSTANCE_DETAILS[$SELECTION]}"
fi

echo ""

# Get current state of selected instance
CURRENT_STATE=$(aws ec2 describe-instances \
    --instance-ids "$SELECTED_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)

echo "Current instance state: $CURRENT_STATE"

# If instance is already stopped, just start it
if [[ "$CURRENT_STATE" == "stopped" ]]; then
    echo "Instance is already stopped. Starting instance..."
    aws ec2 start-instances --instance-ids "$SELECTED_INSTANCE_ID" > /dev/null
    echo "Start command sent. Waiting for instance to be running..."
    
    aws ec2 wait instance-running --instance-ids "$SELECTED_INSTANCE_ID"
    echo "✅ Instance is now running!"
    cleanup_and_exit 0 "Instance started successfully"
fi

# If instance is not running, we can't restart it
if [[ "$CURRENT_STATE" != "running" ]]; then
    echo "Instance is in '$CURRENT_STATE' state. Can only restart running instances."
    cleanup_and_exit 1 "Instance not in running state"
fi

# Stop the instance
echo "Stopping instance $SELECTED_INSTANCE_ID..."
aws ec2 stop-instances --instance-ids "$SELECTED_INSTANCE_ID" > /dev/null

echo "Stop command sent. Waiting for instance to stop (timeout: ${STOP_TIMEOUT}s)..."

# Wait for instance to stop with timeout
WAIT_START=$(date +%s)
while true; do
    CURRENT_STATE=$(aws ec2 describe-instances \
        --instance-ids "$SELECTED_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)
    
    if [[ "$CURRENT_STATE" == "stopped" ]]; then
        echo "✅ Instance stopped successfully!"
        break
    fi
    
    WAIT_ELAPSED=$(($(date +%s) - WAIT_START))
    if [[ $WAIT_ELAPSED -ge $STOP_TIMEOUT ]]; then
        echo ""
        echo "⚠️  Timeout reached after ${STOP_TIMEOUT}s. Instance is still in '$CURRENT_STATE' state."
        read -p "Do you want to force stop the instance? (y/N): " FORCE_STOP
        
        if [[ "$FORCE_STOP" =~ ^[Yy]$ ]]; then
            echo "Force stopping instance..."
            aws ec2 stop-instances --instance-ids "$SELECTED_INSTANCE_ID" --force > /dev/null
            echo "Force stop command sent. Waiting for instance to stop..."
            aws ec2 wait instance-stopped --instance-ids "$SELECTED_INSTANCE_ID"
            echo "✅ Instance force stopped!"
            break
        else
            echo "Operation cancelled."
            cleanup_and_exit 1 "Stop operation timed out and force stop declined"
        fi
    fi
    
    echo -n "."
    sleep 5
done

# Start the instance
echo ""
echo "Starting instance $SELECTED_INSTANCE_ID..."
aws ec2 start-instances --instance-ids "$SELECTED_INSTANCE_ID" > /dev/null

echo "Start command sent. Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$SELECTED_INSTANCE_ID"

echo "✅ Instance is now running!"

# Get the new private IP (it might have changed)
NEW_PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids "$SELECTED_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

echo "New private IP: $NEW_PRIVATE_IP"

cleanup_and_exit 0 "Instance restarted successfully. New IP: $NEW_PRIVATE_IP"
