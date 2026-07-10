# RDS Snapshot Copy and Share Script

A script for creating an RDS snapshot, sharing it with another AWS account, and copying it to the target account.

## Features

- Creates an RDS snapshot in the source account
- Shares the snapshot with a target AWS account
- Copies the snapshot to the target account
- Uses AWS CLI profiles for authentication
- Optional notifications via ntfy.sh for each completed step
- Tracks and reports execution time for each operation
- Supports optional region overrides
- Provides a dry run mode for testing

## Requirements

- AWS CLI installed and configured with profiles for both source and target accounts
- Bash shell environment
- curl (for sending notifications, only if notification feature is used)
- Internet connectivity (for ntfy.sh notifications, only if notification feature is used)

## Configuration

The script supports two methods of configuration:

### Method 1: Using a .env File (Recommended)

Create a `.env` file in the same directory as the script with the following variables:

```
SOURCE_AWS_PROFILE=source-profile       # AWS CLI profile for source account
TARGET_AWS_PROFILE=target-profile       # AWS CLI profile for target account
SOURCE_KMS_KEY_ARN=arn:aws:kms:...      # KMS key ARN for encryption
SOURCE_RDS_INSTANCE=my-database         # RDS instance identifier to snapshot

# Optional variables
NTFY_TOPIC=my-notification-topic        # ntfy.sh topic for notifications (optional)
SOURCE_AWS_REGION=us-east-1             # Region for source account (defaults to profile)
TARGET_AWS_REGION=us-west-2             # Region for target account (defaults to profile)
```

### Method 2: Using Environment Variables

You can also set the configuration directly as environment variables:

```bash
# Set required variables
export SOURCE_AWS_PROFILE=source-profile
export TARGET_AWS_PROFILE=target-profile
export SOURCE_KMS_KEY_ARN=arn:aws:kms:...
export SOURCE_RDS_INSTANCE=my-database

# Optional variables
export NTFY_TOPIC=my-notification-topic  # For notifications
export SOURCE_AWS_REGION=us-east-1       # Source region
export TARGET_AWS_REGION=us-west-2       # Target region

# Run the script
./share-rds-snapshot.sh
```

**Note**: If both methods are used, environment variables take precedence over values in the `.env` file.

## Usage

### Basic Usage

```bash
# Make the script executable (first time only)
chmod +x share-rds-snapshot.sh

# Run the script
./share-rds-snapshot.sh
```

### Checking Instance Status

The script checks if the RDS instance is in the 'available' state before creating a snapshot. If the instance is not available, you have two options:

1. **Default behavior**: The script will abort with an error message
2. **Wait for availability**: Use the `--wait-for-instance` flag to have the script wait for the instance to become available:

```bash
./share-rds-snapshot.sh --wait-for-instance
```

With this flag, the script will wait for up to 15 minutes for the RDS instance to become available before proceeding.

### Dry Run Mode

To preview what the script would do without making any actual changes:

```bash
./share-rds-snapshot.sh --dry-run
```

In dry run mode, the script will:
- Execute read-only AWS API calls (like checking account IDs and resource information)
- Simulate write operations - it will only display what would be executed without making any API calls
- Show detailed logs of what actions would be performed
- Not wait for operations that would normally take time
- Not send actual ntfy notifications (if configured)

This provides a completely safe preview of what would happen during an actual run while keeping your AWS environment unchanged.

### Canceling a Snapshot

If you need to cancel and delete a snapshot that was created by this script:

```bash
./share-rds-snapshot.sh --cancel SNAPSHOT_IDENTIFIER
```

The cancel operation will:
1. Look for the snapshot in both source and target accounts
2. Check the snapshot's current status and wait if it's in a transitional state
3. Remove any sharing permissions if the snapshot is shared
4. Delete the snapshot
5. Send a notification (if notifications are configured)

Example:
```bash
./share-rds-snapshot.sh --cancel my-database-snapshot-20250703123456
```

If the snapshot is in a transitional state (like "creating" or "copying"), the script will wait for up to 10 minutes for it to reach an "available" or "failed" state before attempting to delete it.

### Help

To view the built-in help:

```bash
./share-rds-snapshot.sh --help
```

## Installation

### Method 1: Clone the Repository

```bash
# Clone the repository
git clone https://github.com/username/rds-snapshot-tool.git
cd rds-snapshot-tool

# Create your .env file
cp .env.example .env
# Edit .env with your configuration

# Make the script executable
chmod +x share-rds-snapshot.sh
```

### Method 2: Direct Download

```bash
# Using curl
curl -s https://raw.githubusercontent.com/username/rds-snapshot-tool/main/share-rds-snapshot.sh > share-rds-snapshot.sh

# Using wget
wget https://raw.githubusercontent.com/username/rds-snapshot-tool/main/share-rds-snapshot.sh

# Make the script executable
chmod +x share-rds-snapshot.sh

# Create your .env file
# Create your .env file (Method 1)
cat > .env << EOL
SOURCE_AWS_PROFILE=your-source-profile
TARGET_AWS_PROFILE=your-target-profile
SOURCE_KMS_KEY_ARN=your-kms-key-arn
SOURCE_RDS_INSTANCE=your-rds-instance
# Optional configuration
# NTFY_TOPIC=your-ntfy-topic
# SOURCE_AWS_REGION=us-east-1
# TARGET_AWS_REGION=us-west-2
EOL

# OR use environment variables (Method 2)
export SOURCE_AWS_PROFILE=your-source-profile
export TARGET_AWS_PROFILE=your-target-profile
export SOURCE_KMS_KEY_ARN=your-kms-key-arn
export SOURCE_RDS_INSTANCE=your-rds-instance
```

## Example Output

Normal run:
```
Starting RDS snapshot creation and sharing process...
Creating snapshot of my-database...
Waiting for snapshot to be available...
Step 1 completed in 05:23:17
Source Account ID: 123456789012
Target Account ID: 987654321098
Step 2 completed in 00:00:03
Sharing snapshot with target account 987654321098...
Step 3 completed in 00:00:02
Snapshot ARN: arn:aws:rds:us-east-1:123456789012:snapshot:my-database-snapshot-20250703123456
Copying snapshot in target account as my-database-copy-20250703123456...
Waiting for copied snapshot to be available in target account...
Step 4 completed in 03:15:42
Process completed successfully in 08:39:04!
Summary of timings:
- Step 1 (Create snapshot): 05:23:17
- Step 2 (Get account IDs): 00:00:03
- Step 3 (Share snapshot): 00:00:02
- Step 4 (Copy snapshot): 03:15:42
- Total time: 08:39:04
```

Dry run:
```
=== DRY RUN MODE: No actual changes will be made ===
Starting RDS snapshot creation and sharing process...
Creating snapshot of my-database...
[DRY RUN] Would execute: aws rds create-db-snapshot --db-instance-identifier my-database --db-snapshot-identifier my-database-snapshot-20250703123456 --profile source-profile
[DRY RUN] Would wait for snapshot to become available
[DRY RUN] Would get source account ID, using placeholder: dry-run-source-account
Source Account ID: dry-run-source-account
[DRY RUN] Would get target account ID, using placeholder: dry-run-target-account
Target Account ID: dry-run-target-account
...
Dry run completed in 00:00:05!
[DRY RUN] Summary of operations that would be performed:
- Create snapshot 'my-database-snapshot-20250703123456' for RDS instance 'my-database'
- Share snapshot with target account 'dry-run-target-account'
- Copy snapshot to target account as 'my-database-copy-20250703123456'
- Send notifications for each completed step

To execute these operations for real, run the script without the --dry-run flag.
```

## Automation

### Scheduled Execution (Cron)

To run the script automatically on a schedule, add it to your crontab:

```bash
# Edit crontab
crontab -e

# Add a line to run it daily at 2 AM
0 2 * * * cd /path/to/script/directory && ./share-rds-snapshot.sh >> /var/log/rds-snapshot.log 2>&1
```

## Notifications (Optional)

The script can send notifications via ntfy.sh at the following points if the `NTFY_TOPIC` variable is set in your `.env` file:
- After creating the snapshot
- After identifying source and target account IDs
- After sharing the snapshot
- After copying the snapshot to target account
- Upon completion with timing summary

To enable notifications:
1. Add `NTFY_TOPIC=your-topic-name` to your `.env` file
2. Ensure you have internet connectivity to reach ntfy.sh

If `NTFY_TOPIC` is not set, the script will run without sending notifications.

## Troubleshooting

Common issues:

1. **AWS CLI not installed or configured**:
   - Ensure AWS CLI is installed: `aws --version`
   - Verify profiles exist: `cat ~/.aws/config`

2. **Permission issues**:
   - Ensure the source account has permissions to create and share snapshots
   - Ensure the target account has permissions to copy snapshots
   - Verify KMS key permissions

3. **Network issues**:
   - Check internet connectivity for ntfy.sh notifications
   - Ensure AWS endpoints are accessible

## Security Considerations

- The script uses AWS profiles for authentication, avoiding hardcoded credentials
- Keep your .env file secure and do not commit it to version control
- Consider using AWS IAM roles with least privilege principles
- Regularly rotate your AWS access keys and KMS keys

## License

MIT License

Copyright (c) 2025 Louis Ricohermoso

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.