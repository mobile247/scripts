#!/bin/bash
# EC2 Instance Starter with Retry Logic and Notifications
# Handles 'Insufficient capacity' errors with exponential backoff

set -euo pipefail

# Default values
MAX_RETRIES=10
BASE_DELAY=30
INSTANCE_ID=""

# Function to display usage
usage() {
    echo "Usage: $0 <instance-id> [options]"
    echo ""
    echo "Arguments:"
    echo "  instance-id          EC2 instance ID to start (required)"
    echo ""
    echo "Options:"
    echo "  --max-retries NUM    Maximum number of retry attempts (default: 10)"
    echo "  --base-delay NUM     Base delay in seconds between retries (default: 30)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  NTFY_TOPIC          Topic for ntfy notifications (optional)"
    echo "  NTFY_URL            ntfy server base URL, https only (default: https://ntfy.sh)"
    echo "  NTFY_TOKEN          ntfy access token (Bearer), sent only to NTFY_URL"
    exit 1
}

# Function to send notification via ntfy
# ntfy publish helper.
#   NTFY_TOPIC  topic to publish to (unset = notifications skipped)
#   NTFY_URL    server base URL, https only (unset = public https://ntfy.sh)
#   NTFY_TOKEN  access token for NTFY_URL, sent as "Authorization: Bearer <token>".
#               Only ever sent to NTFY_URL - never to the public ntfy.sh fallback.
# Usage: ntfy_publish <title> <message> [priority]
ntfy_publish() {
    local title="$1" message="$2" priority="${3:-default}"
    [ -n "${NTFY_TOPIC:-}" ] || return 0
    local base="${NTFY_URL:-https://ntfy.sh}" token=""
    case "$base" in
        https://*) ;;
        *) echo "ntfy: NTFY_URL must start with https:// - notification skipped" >&2; return 0 ;;
    esac
    if [ -n "${NTFY_URL:-}" ]; then
        token="${NTFY_TOKEN:-}"
    elif [ -n "${NTFY_TOKEN:-}" ]; then
        echo "ntfy: NTFY_TOKEN is set but NTFY_URL is not - publishing to public ntfy.sh without the token" >&2
    fi
    local url="${base%/}/${NTFY_TOPIC}"
    # Custom User-Agent: some CDN bot filters reject default client agents
    local ua="mobile247-scripts/1.0"
    if command -v curl >/dev/null 2>&1; then
        # Token goes in via a stdin config (-K -) so it never shows up in the process list
        if [ -n "$token" ]; then
            printf 'header = "Authorization: Bearer %s"\n' "$token"
        fi | curl -fsS -o /dev/null -K - -A "$ua" \
            -H "Title: ${title}" -H "Priority: ${priority}" -d "$message" "$url" \
            || echo "ntfy: publish to topic '${NTFY_TOPIC}' failed" >&2
    elif command -v wget >/dev/null 2>&1; then
        local wget_args=(-q -O /dev/null -U "$ua" --header="Title: ${title}" --header="Priority: ${priority}" --post-data="$message")
        if [ -n "$token" ]; then
            wget_args+=(--header="Authorization: Bearer ${token}")
        fi
        wget "${wget_args[@]}" "$url" || echo "ntfy: publish to topic '${NTFY_TOPIC}' failed" >&2
    else
        echo "ntfy: neither curl nor wget found - notification skipped" >&2
    fi
    return 0
}

send_notification() {
    ntfy_publish "start-instance" "$1"
}

# Function to get current instance state
get_instance_state() {
    local instance_id="$1"
    aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "NOT_FOUND"
}

# Function to start instance with retry logic
start_instance_with_retry() {
    local instance_id="$1"
    local max_retries="$2"
    local base_delay="$3"
    local start_time
    start_time=$(date +%s)
    
    # Check if instance exists and get current state
    echo "Checking instance $instance_id..."
    local current_state
    current_state=$(get_instance_state "$instance_id")
    
    if [[ "$current_state" == "NOT_FOUND" ]]; then
        local elapsed=$(($(date +%s) - start_time))
        local error_msg="❌ Instance $instance_id not found"
        echo "$error_msg"
        send_notification "$error_msg"
        return 1
    fi
    
    echo "Instance $instance_id current state: $current_state"
    
    if [[ "$current_state" == "running" ]]; then
        local elapsed=$(($(date +%s) - start_time))
        local message="✅ Instance $instance_id is already running (checked in ${elapsed}s)"
        echo "$message"
        send_notification "$message"
        return 0
    fi
    
    # Attempt to start the instance with retry logic
    for ((attempt=1; attempt<=max_retries; attempt++)); do
        echo "Attempt $attempt/$max_retries: Starting instance $instance_id..."
        
        # Try to start the instance
        local start_output
        if start_output=$(aws ec2 start-instances --instance-ids "$instance_id" 2>&1); then
            echo "Start command successful. Waiting for instance to be running..."
            
            # Wait for instance to be running
            if aws ec2 wait instance-running --instance-ids "$instance_id" --cli-read-timeout 600 --cli-connect-timeout 60; then
                local elapsed=$(($(date +%s) - start_time))
                local success_msg="✅ Instance $instance_id started successfully in ${elapsed}s (attempt $attempt)"
                echo "$success_msg"
                send_notification "$success_msg"
                return 0
            else
                echo "Timeout waiting for instance to reach running state"
            fi
        else
            # Parse the error
            if echo "$start_output" | grep -q "InsufficientInstanceCapacity\|Insufficient capacity"; then
                echo "Error on attempt $attempt: Insufficient capacity detected"
                
                if [[ $attempt -lt $max_retries ]]; then
                    local delay=$((base_delay * (2 ** (attempt - 1))))
                    echo "Waiting $delay seconds before retry..."
                    sleep "$delay"
                    continue
                else
                    local elapsed=$(($(date +%s) - start_time))
                    local failure_msg="❌ Instance $instance_id failed to start after $max_retries attempts (${elapsed}s). Final error: Insufficient capacity"
                    echo "$failure_msg"
                    send_notification "$failure_msg"
                    return 1
                fi
            else
                # Other AWS errors - don't retry
                local elapsed=$(($(date +%s) - start_time))
                local error_detail
                error_detail=$(echo "$start_output" | head -1)
                local failure_msg="❌ Instance $instance_id failed to start (${elapsed}s). Error: $error_detail"
                echo "$failure_msg"
                send_notification "$failure_msg"
                return 1
            fi
        fi
    done
    
    return 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --max-retries)
            if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                MAX_RETRIES="$2"
                shift 2
            else
                echo "Error: --max-retries requires a numeric argument"
                exit 1
            fi
            ;;
        --base-delay)
            if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                BASE_DELAY="$2"
                shift 2
            else
                echo "Error: --base-delay requires a numeric argument"
                exit 1
            fi
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Error: Unknown option $1"
            usage
            ;;
        *)
            if [[ -z "$INSTANCE_ID" ]]; then
                INSTANCE_ID="$1"
                shift
            else
                echo "Error: Multiple instance IDs provided"
                usage
            fi
            ;;
    esac
done

# Check if instance ID was provided
if [[ -z "$INSTANCE_ID" ]]; then
    echo "Error: Instance ID is required"
    usage
fi

# Validate instance ID format
if [[ ! "$INSTANCE_ID" =~ ^i-[0-9a-f]{8,17}$ ]]; then
    echo "Warning: Instance ID format looks unusual: $INSTANCE_ID"
fi

# Check if AWS CLI is available
if ! command -v aws >/dev/null 2>&1; then
    echo "Error: AWS CLI is not installed or not in PATH"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "Error: AWS credentials not configured or invalid"
    exit 1
fi

# Main execution
echo "Starting EC2 instance: $INSTANCE_ID"
echo "Max retries: $MAX_RETRIES"
echo "Base delay: $BASE_DELAY seconds"
echo "$(printf '%*s' 50 '' | tr ' ' '-')"

SCRIPT_START_TIME=$(date +%s)

if start_instance_with_retry "$INSTANCE_ID" "$MAX_RETRIES" "$BASE_DELAY"; then
    SCRIPT_END_TIME=$(date +%s)
    TOTAL_ELAPSED=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
    echo "Script completed successfully in ${TOTAL_ELAPSED}s"
    exit 0
else
    SCRIPT_END_TIME=$(date +%s)
    TOTAL_ELAPSED=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
    echo "Script failed after ${TOTAL_ELAPSED}s"
    exit 1
fi