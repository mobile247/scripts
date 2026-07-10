#!/bin/bash
# =========================================================================
# RDS Snapshot Copy and Share Script
# For detailed documentation, see share-rds-snapshot.md
# =========================================================================

set -e

# Parse command line arguments
DRY_RUN=false
HELP=false
CANCEL_SNAPSHOT=""
WAIT_FOR_INSTANCE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      HELP=true
      shift
      ;;
    --cancel)
      if [[ -z "$2" || "$2" == --* ]]; then
        echo "Error: --cancel requires a snapshot identifier"
        exit 1
      fi
      CANCEL_SNAPSHOT="$2"
      shift 2
      ;;
    --wait-for-instance)
      WAIT_FOR_INSTANCE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--dry-run] [--help] [--cancel SNAPSHOT_IDENTIFIER] [--wait-for-instance]"
      exit 1
      ;;
  esac
done

# Display help information
if [ "$HELP" = true ]; then
  echo "RDS Snapshot Copy and Share Script"
  echo ""
  echo "This script creates an RDS snapshot, shares it with another AWS account,"
  echo "and copies it to the target account."
  echo ""
  echo "Usage:"
  echo "  ./share-rds-snapshot.sh [--dry-run] [--help] [--cancel SNAPSHOT_IDENTIFIER] [--wait-for-instance]"
  echo ""
  echo "Options:"
  echo "  --dry-run                Show what would be done without making any actual changes"
  echo "  --help, -h               Display this help message"
  echo "  --cancel SNAPSHOT_ID     Cancel and delete a snapshot by its identifier"
  echo "  --wait-for-instance      Wait for the RDS instance to become available before creating a snapshot"
  echo ""
  echo "Required Environment Variables (.env file or exported):"
  echo "  SOURCE_AWS_PROFILE     AWS CLI profile for the source account"
  echo "  TARGET_AWS_PROFILE     AWS CLI profile for the target account"
  echo "  SOURCE_KMS_KEY_ARN     KMS key ARN used for encryption"
  echo "  SOURCE_RDS_INSTANCE    Identifier of the RDS instance to snapshot"
  echo ""
  echo "Optional Environment Variables:"
  echo "  NTFY_TOPIC             Topic for ntfy.sh notifications (optional)"
  echo "  SOURCE_AWS_REGION      Region for source account (defaults to profile)"
  echo "  TARGET_AWS_REGION      Region for target account (defaults to profile)"
  exit 0
fi

# Load environment variables
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
  echo "Loaded configuration from .env file"
else
  echo "No .env file found, using environment variables"
fi

# Check if required environment variables are set
required_vars=("SOURCE_AWS_PROFILE" "TARGET_AWS_PROFILE" "SOURCE_KMS_KEY_ARN" "SOURCE_RDS_INSTANCE")
for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    echo "Error: $var is not set in .env file"
    exit 1
  fi
done

# Set region parameters
SOURCE_REGION_PARAM=""
if [ -n "$SOURCE_AWS_REGION" ]; then
  SOURCE_REGION_PARAM="--region $SOURCE_AWS_REGION"
  echo "Using source region: $SOURCE_AWS_REGION"
else
  echo "Using default source region from AWS profile"
fi

TARGET_REGION_PARAM=""
if [ -n "$TARGET_AWS_REGION" ]; then
  TARGET_REGION_PARAM="--region $TARGET_AWS_REGION"
  echo "Using target region: $TARGET_AWS_REGION"
else
  echo "Using default target region from AWS profile"
fi

# Check if notifications are enabled
if [ -n "$NTFY_TOPIC" ]; then
  echo "Notifications enabled: Will send updates to ntfy.sh/$NTFY_TOPIC"
else
  echo "Notifications disabled: NTFY_TOPIC not set in .env"
fi

# Function to send notifications
send_notification() {
  local message="$1"
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would send notification: $message"
  elif [ -n "$NTFY_TOPIC" ]; then
    curl -d "$message" "https://ntfy.sh/$NTFY_TOPIC"
  else
    # Skip notification if NTFY_TOPIC is not set
    :
  fi
}

# Function to execute or simulate AWS commands
run_aws_command() {
  local service=$1
  local operation=$2
  shift 2
  
  # Check if this is a write operation that should be simulated in dry run mode
  if [[ "$DRY_RUN" == "true" && "$operation" =~ ^(create|modify|copy|update|delete|put) ]]; then
    echo "[DRY RUN] Would execute: aws $service $operation $@"
    # Simulate success for dry runs
    return 0
  else
    # For read operations or non-dry-run mode, actually execute the command
    aws "$service" "$operation" "$@"
    return $?
  fi
}

# Function to calculate elapsed time
calculate_elapsed() {
  local start_time=$1
  local end_time=$2
  local elapsed_seconds=$((end_time - start_time))
  local hours=$((elapsed_seconds / 3600))
  local minutes=$(((elapsed_seconds % 3600) / 60))
  local seconds=$((elapsed_seconds % 60))
  
  printf "%02d:%02d:%02d" $hours $minutes $seconds
}

# Function to check RDS instance status and wait if necessary
check_instance_status() {
  local instance_id="$1"
  local profile="$2"
  local region_param="$3"
  local wait_if_needed="$4"
  
  echo "Checking status of RDS instance $instance_id..."
  
  # Check if the instance exists
  if ! aws rds describe-db-instances --db-instance-identifier "$instance_id" --profile "$profile" $region_param &>/dev/null; then
    echo "Error: RDS instance $instance_id not found"
    return 1
  fi
  
  # Get the current status
  local instance_status
  instance_status=$(aws rds describe-db-instances \
    --db-instance-identifier "$instance_id" \
    --profile "$profile" \
    $region_param \
    --query "DBInstances[0].DBInstanceStatus" \
    --output text)
  
  echo "Current RDS instance status: $instance_status"
  
  # If the instance is available, we're good to go
  if [ "$instance_status" = "available" ]; then
    echo "RDS instance is available. Proceeding with snapshot creation."
    return 0
  fi
  
  # If we're not waiting, exit with an error
  if [ "$wait_if_needed" != "true" ]; then
    echo "Error: RDS instance is not in 'available' state. Current state: $instance_status"
    echo "You can use the --wait-for-instance flag to wait for the instance to become available."
    return 1
  fi
  
  # Wait for the instance to become available
  echo "Waiting for RDS instance to become available..."
  local wait_count=0
  local max_wait=30  # Maximum number of retries (30 * 30 seconds = 15 minutes)
  
  while [ $wait_count -lt $max_wait ]; do
    sleep 30
    instance_status=$(aws rds describe-db-instances \
      --db-instance-identifier "$instance_id" \
      --profile "$profile" \
      $region_param \
      --query "DBInstances[0].DBInstanceStatus" \
      --output text 2>/dev/null || echo "not_found")
    
    echo "Current status: $instance_status"
    
    if [ "$instance_status" = "available" ]; then
      echo "RDS instance is now available. Proceeding with snapshot creation."
      return 0
    elif [ "$instance_status" = "not_found" ]; then
      echo "Error: RDS instance no longer exists."
      return 1
    fi
    
    wait_count=$((wait_count + 1))
    echo "Waiting for RDS instance to become available... ($wait_count/$max_wait)"
  done
  
  echo "Timed out waiting for RDS instance to become available."
  return 1
}

# Function to cancel and delete a snapshot
cancel_snapshot() {
  local snapshot_id="$1"
  local profile="$SOURCE_AWS_PROFILE"
  local region_param="$SOURCE_REGION_PARAM"
  
  echo "Checking snapshot $snapshot_id..."
  
  # First, check if the snapshot exists
  if ! aws rds describe-db-snapshots --db-snapshot-identifier "$snapshot_id" --profile "$profile" $region_param &>/dev/null; then
    echo "Error: Snapshot $snapshot_id not found in account using profile $profile"
    
    # Try to check in the target account as well
    echo "Checking if snapshot exists in target account..."
    if ! aws rds describe-db-snapshots --db-snapshot-identifier "$snapshot_id" --profile "$TARGET_AWS_PROFILE" $TARGET_REGION_PARAM &>/dev/null; then
      echo "Error: Snapshot $snapshot_id not found in either source or target account"
      return 1
    else
      # Found in target account, update variables to use target account
      profile="$TARGET_AWS_PROFILE"
      region_param="$TARGET_REGION_PARAM"
      echo "Found snapshot in target account, will delete from there."
    fi
  else
    echo "Found snapshot in source account."
  fi
  
  # Check the current status of the snapshot
  local snapshot_status
  snapshot_status=$(aws rds describe-db-snapshots \
    --db-snapshot-identifier "$snapshot_id" \
    --profile "$profile" \
    $region_param \
    --query "DBSnapshots[0].Status" \
    --output text)
  
  echo "Current snapshot status: $snapshot_status"
  
  # If the snapshot is not in 'available' state, wait for it
  if [ "$snapshot_status" != "available" ] && [ "$snapshot_status" != "failed" ]; then
    echo "Snapshot is currently in '$snapshot_status' state. Waiting for it to become available or failed..."
    
    # Wait for the snapshot to become available or failed
    local wait_count=0
    local max_wait=30  # Maximum number of retries (30 * 20 seconds = 10 minutes)
    
    while [ $wait_count -lt $max_wait ]; do
      sleep 20
      snapshot_status=$(aws rds describe-db-snapshots \
        --db-snapshot-identifier "$snapshot_id" \
        --profile "$profile" \
        $region_param \
        --query "DBSnapshots[0].Status" \
        --output text 2>/dev/null || echo "not_found")
      
      echo "Current status: $snapshot_status"
      
      if [ "$snapshot_status" == "available" ] || [ "$snapshot_status" == "failed" ]; then
        echo "Snapshot is now in a deletable state."
        break
      elif [ "$snapshot_status" == "not_found" ]; then
        echo "Snapshot no longer exists."
        return 0
      fi
      
      wait_count=$((wait_count + 1))
      echo "Waiting for snapshot to become available or failed... ($wait_count/$max_wait)"
    done
    
    if [ $wait_count -eq $max_wait ]; then
      echo "Timed out waiting for snapshot to become available. Please try again later."
      return 1
    fi
  fi
  
  # Check if the snapshot is being shared
  local shared_accounts
  shared_accounts=$(aws rds describe-db-snapshot-attributes \
    --db-snapshot-identifier "$snapshot_id" \
    --profile "$profile" \
    $region_param \
    --query "DBSnapshotAttributesResult.DBSnapshotAttributes[?AttributeName=='restore'].AttributeValues[0]" \
    --output text)
  
  # If the snapshot is shared, remove the sharing first
  if [ -n "$shared_accounts" ] && [ "$shared_accounts" != "None" ]; then
    echo "Removing sharing for snapshot $snapshot_id with account $shared_accounts..."
    aws rds modify-db-snapshot-attribute \
      --db-snapshot-identifier "$snapshot_id" \
      --attribute-name restore \
      --values-to-remove "$shared_accounts" \
      --profile "$profile" \
      $region_param
    
    echo "Waiting a moment for share removal to process..."
    sleep 5
  fi
  
  # Delete the snapshot
  echo "Deleting snapshot $snapshot_id..."
  if ! aws rds delete-db-snapshot \
    --db-snapshot-identifier "$snapshot_id" \
    --profile "$profile" \
    $region_param; then
    echo "Error deleting snapshot. It may be in use or in a protected state."
    return 1
  fi
  
  echo "Waiting for snapshot to be deleted..."
  local delete_wait_count=0
  local max_delete_wait=30  # Maximum number of retries (30 * 20 seconds = 10 minutes)
  
  while [ $delete_wait_count -lt $max_delete_wait ]; do
    if ! aws rds describe-db-snapshots --db-snapshot-identifier "$snapshot_id" --profile "$profile" $region_param &>/dev/null; then
      echo "Snapshot has been successfully deleted."
      break
    fi
    
    delete_wait_count=$((delete_wait_count + 1))
    echo "Still deleting... ($delete_wait_count/$max_delete_wait)"
    sleep 20
  done
  
  if [ $delete_wait_count -eq $max_delete_wait ]; then
    echo "Timed out waiting for snapshot to be deleted. It may still be in the process of being deleted."
    return 1
  fi
  
  # Send notification if configured
  if [ -n "$NTFY_TOPIC" ]; then
    send_notification "🗑️ Snapshot $snapshot_id has been deleted"
  fi
  
  return 0
}

# Handle snapshot cancellation if requested
if [ -n "$CANCEL_SNAPSHOT" ]; then
  echo "Cancellation mode: Will attempt to delete snapshot $CANCEL_SNAPSHOT"
  cancel_snapshot "$CANCEL_SNAPSHOT"
  exit $?
fi

# Start tracking total time
TOTAL_START_TIME=$(date +%s)

# Generate timestamp for snapshot name
TIMESTAMP=$(date +%Y%m%d%H%M%S)
SNAPSHOT_NAME="${SOURCE_RDS_INSTANCE}-snapshot-${TIMESTAMP}"

if [ "$DRY_RUN" = true ]; then
  echo "=== DRY RUN MODE: No actual changes will be made ==="
fi

echo "Starting RDS snapshot creation and sharing process..."

# Step 1: Create a snapshot of the source RDS instance
echo "Creating snapshot of ${SOURCE_RDS_INSTANCE}..."
STEP1_START_TIME=$(date +%s)

# Check if the RDS instance is available (only in non-dry-run mode)
if [ "$DRY_RUN" = false ]; then
  if ! check_instance_status "$SOURCE_RDS_INSTANCE" "$SOURCE_AWS_PROFILE" "$SOURCE_REGION_PARAM" "$WAIT_FOR_INSTANCE"; then
    echo "Aborting: Cannot create snapshot when the RDS instance is not available."
    exit 1
  fi
else
  echo "[DRY RUN] Would check if RDS instance ${SOURCE_RDS_INSTANCE} is available"
fi

# In dry run mode, we just simulate the command without executing it
if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would execute: aws rds create-db-snapshot --db-instance-identifier \"$SOURCE_RDS_INSTANCE\" --db-snapshot-identifier \"$SNAPSHOT_NAME\" --profile \"$SOURCE_AWS_PROFILE\" $SOURCE_REGION_PARAM"
else
  # Only in non-dry-run mode do we actually execute the command
  if ! aws rds create-db-snapshot \
    --db-instance-identifier "$SOURCE_RDS_INSTANCE" \
    --db-snapshot-identifier "$SNAPSHOT_NAME" \
    --profile "$SOURCE_AWS_PROFILE" \
    $SOURCE_REGION_PARAM; then
    echo "Error creating snapshot. Aborting."
    exit 1
  fi
fi

# Wait for the snapshot to be available
if [ "$DRY_RUN" = false ]; then
  echo "Waiting for snapshot to be available..."
  aws rds wait db-snapshot-available \
    --db-snapshot-identifier "$SNAPSHOT_NAME" \
    --profile "$SOURCE_AWS_PROFILE" \
    $SOURCE_REGION_PARAM
else
  echo "[DRY RUN] Would wait for snapshot to become available"
fi

STEP1_END_TIME=$(date +%s)
STEP1_ELAPSED=$(calculate_elapsed $STEP1_START_TIME $STEP1_END_TIME)
echo "Step 1 completed in $STEP1_ELAPSED"

send_notification "✅ Step 1 complete: Created snapshot $SNAPSHOT_NAME for $SOURCE_RDS_INSTANCE (Time: $STEP1_ELAPSED)"

# Fix the function calls for all usages of run_aws_command
# Step 2: Get the source account ID
STEP2_START_TIME=$(date +%s)
if [ "$DRY_RUN" = true ]; then
  # Use placeholder account IDs in dry run mode
  SOURCE_ACCOUNT_ID="123456789012"
  echo "[DRY RUN] Would get source account ID, using placeholder: $SOURCE_ACCOUNT_ID"
else
  SOURCE_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile "$SOURCE_AWS_PROFILE" $SOURCE_REGION_PARAM)
fi
echo "Source Account ID: $SOURCE_ACCOUNT_ID"

# Step 3: Get the target account ID
if [ "$DRY_RUN" = true ]; then
  # Use placeholder account IDs in dry run mode
  TARGET_ACCOUNT_ID="987654321098"
  echo "[DRY RUN] Would get target account ID, using placeholder: $TARGET_ACCOUNT_ID"
else
  TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile "$TARGET_AWS_PROFILE" $TARGET_REGION_PARAM)
fi
echo "Target Account ID: $TARGET_ACCOUNT_ID"
echo "Target Account ID: $TARGET_ACCOUNT_ID"

STEP2_END_TIME=$(date +%s)
STEP2_ELAPSED=$(calculate_elapsed $STEP2_START_TIME $STEP2_END_TIME)
echo "Step 2 completed in $STEP2_ELAPSED"

send_notification "✅ Step 2 complete: Identified source account $SOURCE_ACCOUNT_ID and target account $TARGET_ACCOUNT_ID (Time: $STEP2_ELAPSED)"

# Step 4: Share the snapshot with the target account
echo "Sharing snapshot with target account ${TARGET_ACCOUNT_ID}..."
STEP3_START_TIME=$(date +%s)

# In dry run mode, we just simulate the command without executing it
if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would execute: aws rds modify-db-snapshot-attribute --db-snapshot-identifier \"$SNAPSHOT_NAME\" --attribute-name restore --values-to-add \"$TARGET_ACCOUNT_ID\" --profile \"$SOURCE_AWS_PROFILE\" $SOURCE_REGION_PARAM"
else
  # Only in non-dry-run mode do we actually execute the command
  if ! aws rds modify-db-snapshot-attribute \
    --db-snapshot-identifier "$SNAPSHOT_NAME" \
    --attribute-name restore \
    --values-to-add "$TARGET_ACCOUNT_ID" \
    --profile "$SOURCE_AWS_PROFILE" \
    $SOURCE_REGION_PARAM; then
    echo "Error sharing snapshot. Continuing with next steps..."
  fi
fi

STEP3_END_TIME=$(date +%s)
STEP3_ELAPSED=$(calculate_elapsed $STEP3_START_TIME $STEP3_END_TIME)
echo "Step 3 completed in $STEP3_ELAPSED"

send_notification "✅ Step 3 complete: Shared snapshot $SNAPSHOT_NAME with target account $TARGET_ACCOUNT_ID (Time: $STEP3_ELAPSED)"

# Step 5: Get the snapshot ARN
STEP4_START_TIME=$(date +%s)

if [ "$DRY_RUN" = true ]; then
  # In dry run, try to get an existing snapshot to demonstrate the proper ARN format
  # If no snapshot exists, use a placeholder ARN
  EXISTING_SNAPSHOT=$(run_aws_command rds describe-db-snapshots --query "DBSnapshots[0].DBSnapshotIdentifier" --output text --profile "$SOURCE_AWS_PROFILE" $SOURCE_REGION_PARAM 2>/dev/null || echo "")
  
  if [ -n "$EXISTING_SNAPSHOT" ] && [ "$EXISTING_SNAPSHOT" != "None" ]; then
    # Get the ARN format from an existing snapshot
    EXAMPLE_ARN=$(run_aws_command rds describe-db-snapshots --db-snapshot-identifier "$EXISTING_SNAPSHOT" --query "DBSnapshots[0].DBSnapshotArn" --output text --profile "$SOURCE_AWS_PROFILE" $SOURCE_REGION_PARAM)
    # Replace the snapshot name in the example ARN
    SNAPSHOT_ARN=$(echo "$EXAMPLE_ARN" | sed "s/$EXISTING_SNAPSHOT/$SNAPSHOT_NAME/")
    echo "Using ARN format from existing snapshots"
  else
    # Construct a placeholder ARN with the correct format
    REGION=${SOURCE_AWS_REGION:-$(aws configure get region --profile "$SOURCE_AWS_PROFILE" || echo "us-east-1")}
    SNAPSHOT_ARN="arn:aws:rds:${REGION}:${SOURCE_ACCOUNT_ID}:snapshot:${SNAPSHOT_NAME}"
    echo "[DRY RUN] No existing snapshots found, using constructed ARN format"
  fi
else
  # In normal mode, get the actual ARN of the snapshot we created
  SNAPSHOT_ARN=$(run_aws_command rds describe-db-snapshots \
    --db-snapshot-identifier "$SNAPSHOT_NAME" \
    --query "DBSnapshots[0].DBSnapshotArn" \
    --output text \
    --profile "$SOURCE_AWS_PROFILE" \
    $SOURCE_REGION_PARAM)
fi
echo "Snapshot ARN: $SNAPSHOT_ARN"

# Step 6: Copy the snapshot in the target account
TARGET_SNAPSHOT_NAME="${SOURCE_RDS_INSTANCE}-copy-${TIMESTAMP}"
echo "Copying snapshot in target account as ${TARGET_SNAPSHOT_NAME}..."

# In dry run mode, we just simulate the command without executing it
if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would execute: aws rds copy-db-snapshot --source-db-snapshot-identifier \"$SNAPSHOT_ARN\" --target-db-snapshot-identifier \"$TARGET_SNAPSHOT_NAME\" --kms-key-id \"$SOURCE_KMS_KEY_ARN\" --profile \"$TARGET_AWS_PROFILE\" $TARGET_REGION_PARAM"
else
  # Only in non-dry-run mode do we actually execute the command
  if ! aws rds copy-db-snapshot \
    --source-db-snapshot-identifier "$SNAPSHOT_ARN" \
    --target-db-snapshot-identifier "$TARGET_SNAPSHOT_NAME" \
    --kms-key-id "$SOURCE_KMS_KEY_ARN" \
    --profile "$TARGET_AWS_PROFILE" \
    $TARGET_REGION_PARAM; then
    echo "Error copying snapshot to target account. Aborting."
    exit 1
  fi
fi

# Wait for the copied snapshot to be available
if [ "$DRY_RUN" = false ]; then
  echo "Waiting for copied snapshot to be available in target account..."
  aws rds wait db-snapshot-available \
    --db-snapshot-identifier "$TARGET_SNAPSHOT_NAME" \
    --profile "$TARGET_AWS_PROFILE" \
    $TARGET_REGION_PARAM
else
  echo "[DRY RUN] Would wait for copied snapshot to become available in target account"
fi

STEP4_END_TIME=$(date +%s)
STEP4_ELAPSED=$(calculate_elapsed $STEP4_START_TIME $STEP4_END_TIME)
echo "Step 4 completed in $STEP4_ELAPSED"

send_notification "✅ Step 4 complete: Copied snapshot to target account as $TARGET_SNAPSHOT_NAME (Time: $STEP4_ELAPSED)"

# Calculate total time
TOTAL_END_TIME=$(date +%s)
TOTAL_ELAPSED=$(calculate_elapsed $TOTAL_START_TIME $TOTAL_END_TIME)

if [ "$DRY_RUN" = true ]; then
  echo "Dry run completed in $TOTAL_ELAPSED!"
  echo "[DRY RUN] Summary of operations that would be performed:"
  echo "- Create snapshot '$SNAPSHOT_NAME' for RDS instance '$SOURCE_RDS_INSTANCE'"
  echo "- Share snapshot with target account '$TARGET_ACCOUNT_ID'"
  echo "- Copy snapshot to target account as '$TARGET_SNAPSHOT_NAME'"
  if [ -n "$NTFY_TOPIC" ]; then
    echo "- Send notifications for each completed step"
  fi
  echo ""
  echo "To execute these operations for real, run the script without the --dry-run flag."
else
  echo "Process completed successfully in $TOTAL_ELAPSED!"
  echo "Summary of timings:"
  echo "- Step 1 (Create snapshot): $STEP1_ELAPSED"
  echo "- Step 2 (Get account IDs): $STEP2_ELAPSED"
  echo "- Step 3 (Share snapshot): $STEP3_ELAPSED"
  echo "- Step 4 (Copy snapshot): $STEP4_ELAPSED"
  echo "- Total time: $TOTAL_ELAPSED"

  send_notification "🎉 Complete: RDS snapshot process finished in $TOTAL_ELAPSED"
  send_notification "📊 Timings: Create: $STEP1_ELAPSED | IDs: $STEP2_ELAPSED | Share: $STEP3_ELAPSED | Copy: $STEP4_ELAPSED"
fi