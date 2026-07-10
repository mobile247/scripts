#!/bin/bash
#
# Script to stop an EC2 instance, change its instance type, and start it again.
# Uses AWS CLI configuration for credentials.
#

set -e

# Record start time
START_TIME=$(date +%s)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DRY_RUN=false
REGION=""

# Function to print colored output
print_error() {
    echo -e "${RED}Error: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
    echo -e "${BLUE}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Function to send ntfy notification
send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"

    if [[ -n "$NTFY_TOPIC" ]]; then
        curl -s -o /dev/null \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -d "$message" \
            "ntfy.sh/$NTFY_TOPIC" 2>/dev/null || true
    fi
}

# Function to calculate and display elapsed time
show_elapsed_time() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))

    if [[ $minutes -gt 0 ]]; then
        echo "Elapsed time: ${minutes}m ${seconds}s"
    else
        echo "Elapsed time: ${seconds}s"
    fi
}

# Function to show usage
usage() {
    cat << EOF
Usage: $0 --instance-id INSTANCE_ID --instance-type INSTANCE_TYPE [OPTIONS]

Stop an EC2 instance, change its type, and start it again.

Required Arguments:
  --instance-id ID          EC2 instance ID (e.g., i-1234567890abcdef0)
  --instance-type TYPE      Target instance type (e.g., t3.medium, m5.xlarge)

Optional Arguments:
  --region REGION           AWS region (uses default from AWS CLI config if not specified)
  --dry-run                 Preview actions without making changes
  -h, --help                Show this help message

Examples:
  # Change instance to t3.medium (dry run)
  $0 --instance-id i-1234567890abcdef0 --instance-type t3.medium --dry-run

  # Actually change the instance type
  $0 --instance-id i-1234567890abcdef0 --instance-type t3.medium

  # With region specified
  $0 --instance-id i-1234567890abcdef0 --instance-type t3.medium --region us-east-1

EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        --instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$INSTANCE_ID" ]]; then
    print_error "Instance ID is required"
    usage
fi

if [[ -z "$INSTANCE_TYPE" ]]; then
    print_error "Instance type is required"
    usage
fi

# Build AWS CLI command with optional region
AWS_CMD="aws ec2"
if [[ -n "$REGION" ]]; then
    AWS_CMD="$AWS_CMD --region $REGION"
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Print header
echo
echo "======================================================================"
if [[ "$DRY_RUN" == true ]]; then
    print_warning "DRY RUN MODE - Preview Only"
else
    print_info "EC2 Instance Type Change"
fi
echo "======================================================================"
echo

# Get current instance information
print_info "Fetching instance information..."
INSTANCE_INFO=$($AWS_CMD describe-instances --instance-ids "$INSTANCE_ID" 2>&1) || {
    print_error "Failed to get instance information. Instance may not exist."
    exit 1
}

CURRENT_TYPE=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].InstanceType')
CURRENT_STATE=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].State.Name')

echo "Instance ID: $INSTANCE_ID"
echo "Current Type: $CURRENT_TYPE"
echo "Target Type: $INSTANCE_TYPE"
echo "Current State: $CURRENT_STATE"

# Check if instance type is already the target type
if [[ "$CURRENT_TYPE" == "$INSTANCE_TYPE" ]]; then
    echo
    echo "======================================================================"
    print_info "Instance is already of type $INSTANCE_TYPE. No changes needed."
    echo
    show_elapsed_time
    echo "======================================================================"
    echo
    exit 0
fi

echo "======================================================================"

# Confirm if not dry run
if [[ "$DRY_RUN" == false ]]; then
    echo
    print_warning "This will stop your EC2 instance!"
    echo "The instance will be unavailable during the type change."
    echo
    read -p "Type 'CHANGE' to confirm and proceed: " CONFIRMATION

    if [[ "$CONFIRMATION" != "CHANGE" ]]; then
        echo "Operation cancelled."
        exit 0
    fi
fi

echo

# Step 1: Stop the instance (if not already stopped)
if [[ "$CURRENT_STATE" != "stopped" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[DRY RUN] Would stop instance: $INSTANCE_ID"
    else
        print_info "Stopping instance: $INSTANCE_ID..."
        $AWS_CMD stop-instances --instance-ids "$INSTANCE_ID" > /dev/null

        echo -n "Waiting for instance to stop"
        $AWS_CMD wait instance-stopped --instance-ids "$INSTANCE_ID"
        echo
        print_success "Instance stopped successfully"
    fi
else
    print_info "Instance is already stopped."
fi

# Step 2: Change instance type
if [[ "$DRY_RUN" == true ]]; then
    print_info "[DRY RUN] Would change instance type to: $INSTANCE_TYPE"
else
    print_info "Changing instance type to: $INSTANCE_TYPE..."
    $AWS_CMD modify-instance-attribute \
        --instance-id "$INSTANCE_ID" \
        --instance-type "{\"Value\":\"$INSTANCE_TYPE\"}" > /dev/null
    print_success "Instance type changed successfully"
fi

# Step 3: Start the instance
if [[ "$DRY_RUN" == true ]]; then
    print_info "[DRY RUN] Would start instance: $INSTANCE_ID"
else
    print_info "Starting instance: $INSTANCE_ID..."
    $AWS_CMD start-instances --instance-ids "$INSTANCE_ID" > /dev/null

    echo -n "Waiting for instance to start"
    $AWS_CMD wait instance-running --instance-ids "$INSTANCE_ID"
    echo
    print_success "Instance started successfully"
fi

# Final summary
echo
echo "======================================================================"
if [[ "$DRY_RUN" == true ]]; then
    print_info "[DRY RUN] Preview complete!"
    echo "Would change instance $INSTANCE_ID"
    echo "From: $CURRENT_TYPE"
    echo "To: $INSTANCE_TYPE"
else
    print_success "Success!"
    echo "Instance $INSTANCE_ID has been changed from $CURRENT_TYPE to $INSTANCE_TYPE"
    echo "Instance is now running."

    # Send success notification
    send_notification \
        "EC2 Instance Type Changed" \
        "Instance $INSTANCE_ID changed from $CURRENT_TYPE to $INSTANCE_TYPE" \
        "default"
fi
echo
show_elapsed_time
echo "======================================================================"
echo
