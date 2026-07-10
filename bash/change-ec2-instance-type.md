# EC2 Instance Type Change Script

This script automates the process of changing an EC2 instance type by stopping the instance, modifying its type, and restarting it. The script handles all the waiting and state management automatically, making it safe and convenient to resize your EC2 instances.

## Features
- Automated stop, modify, and start workflow
- Dry-run mode to preview changes before execution
- Current instance state validation
- Automatic waiting for state transitions
- Color-coded output for better readability
- Safe confirmation prompt before making changes
- Support for custom AWS regions
- Detailed error handling
- Elapsed time tracking
- Optional notifications via ntfy.sh

## Prerequisites

- AWS CLI installed and configured
- `jq` command-line JSON processor
- Appropriate AWS IAM permissions:
  - `ec2:DescribeInstances`
  - `ec2:StopInstances`
  - `ec2:StartInstances`
  - `ec2:ModifyInstanceAttribute`
- bash shell (Linux/macOS)

## Installation

### Install AWS CLI
```bash
# macOS
brew install awscli

# Linux
pip install awscli

# Configure AWS credentials
aws configure
```

### Install jq
```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt-get install jq

# CentOS/RHEL
sudo yum install jq
```

### Make the script executable
```bash
chmod +x change-ec2-instance-type.sh
```

## Usage

### Basic Usage
```bash
./change-ec2-instance-type.sh \
  --instance-id i-1234567890abcdef0 \
  --instance-type t3.medium
```

### Preview Changes (Dry Run)
```bash
./change-ec2-instance-type.sh \
  --instance-id i-1234567890abcdef0 \
  --instance-type t3.medium \
  --dry-run
```

### Specify AWS Region
```bash
./change-ec2-instance-type.sh \
  --instance-id i-1234567890abcdef0 \
  --instance-type t3.medium \
  --region us-east-1
```

### With Notifications
```bash
export NTFY_TOPIC="your-notification-topic"
./change-ec2-instance-type.sh \
  --instance-id i-1234567890abcdef0 \
  --instance-type t3.medium
```

### Show Help
```bash
./change-ec2-instance-type.sh --help
```

## Command Line Arguments

### Required Arguments
- `--instance-id`: The EC2 instance ID (e.g., `i-1234567890abcdef0`)
- `--instance-type`: The target instance type (e.g., `t3.medium`, `m5.xlarge`, `c5.2xlarge`)

### Optional Arguments
- `--region`: AWS region (if not specified, uses the default from your AWS CLI configuration)
- `--dry-run`: Preview what would happen without making any changes
- `-h`, `--help`: Display help message

### Environment Variables
- `NTFY_TOPIC`: Optional ntfy.sh topic for notifications (default: disabled)

## Common Instance Types

| Type | vCPUs | Memory | Use Case |
|------|-------|--------|----------|
| t3.micro | 2 | 1 GiB | Very light workloads |
| t3.small | 2 | 2 GiB | Light workloads |
| t3.medium | 2 | 4 GiB | Small applications |
| t3.large | 2 | 8 GiB | Medium applications |
| m5.large | 2 | 8 GiB | General purpose |
| m5.xlarge | 4 | 16 GiB | General purpose |
| c5.large | 2 | 4 GiB | Compute optimized |
| r5.large | 2 | 16 GiB | Memory optimized |

See [AWS EC2 Instance Types](https://aws.amazon.com/ec2/instance-types/) for a complete list.

## How It Works

1. **Validation**: Checks if the instance exists and retrieves current state
2. **Type Check**: Compares current type with target type (exits if already correct)
3. **Confirmation**: Prompts for confirmation (skipped in dry-run mode)
4. **Stop Instance**: Stops the instance if it's running (waits until fully stopped)
5. **Modify Type**: Changes the instance type attribute
6. **Start Instance**: Starts the instance (waits until fully running)
7. **Summary**: Displays success message with details

## Output Example

```
======================================================================
EC2 Instance Type Change
======================================================================

Fetching instance information...
Instance ID: i-1234567890abcdef0
Current Type: t3.small
Target Type: t3.medium
Current State: running
======================================================================

This will stop your EC2 instance!
The instance will be unavailable during the type change.

Type 'CHANGE' to confirm and proceed: CHANGE

Stopping instance: i-1234567890abcdef0...
Waiting for instance to stop
✓ Instance stopped successfully
Changing instance type to: t3.medium...
✓ Instance type changed successfully
Starting instance: i-1234567890abcdef0...
Waiting for instance to start
✓ Instance started successfully

======================================================================
✓ Success!
Instance i-1234567890abcdef0 has been changed from t3.small to t3.medium
Instance is now running.

Elapsed time: 2m 15s
======================================================================
```

## Notifications

If the `NTFY_TOPIC` environment variable is set, the script will send a notification upon successful completion with:
- Instance ID
- Previous and new instance types
- Success confirmation

Example notification message:
```
Instance i-1234567890abcdef0 changed from t3.small to t3.medium
```

## Error Handling

The script includes comprehensive error handling:

- **Missing AWS CLI**: Checks if AWS CLI is installed
- **Invalid Instance ID**: Validates instance exists before proceeding
- **Already Correct Type**: Exits gracefully if instance is already the target type
- **Permission Errors**: Shows clear error messages if IAM permissions are insufficient
- **State Transition Failures**: Reports if instance fails to stop or start

## Important Notes

### Downtime
- **The instance will be stopped during the type change**, causing downtime
- Plan the change during a maintenance window if the instance serves production traffic
- Use dry-run mode first to verify the change will work

### Instance Store Volumes
- Data on instance store volumes **will be lost** when the instance is stopped
- Only EBS-backed instances retain data through stop/start cycles
- Ensure all important data is on EBS volumes or backed up

### Elastic IP Addresses
- Elastic IP addresses remain associated through the change
- Public IP addresses (non-Elastic) may change after restart

### Compatibility
- Not all instance type changes are compatible (e.g., different virtualization types)
- The script will fail with an error if the change is not allowed
- Some instance types require specific AMIs or kernel versions

## Dry Run Benefits

Always use `--dry-run` first to:
- Verify the instance ID is correct
- Confirm current and target instance types
- Check that you have necessary permissions
- Preview the workflow without risking downtime

## Security Notes

- Uses your configured AWS CLI credentials (`~/.aws/credentials`)
- Requires confirmation before making changes (unless dry-run)
- Does not expose sensitive information in output
- Safe to use in automated scripts with proper IAM role restrictions

## Troubleshooting

### "Failed to get instance information"
- Verify the instance ID is correct
- Check that you have `ec2:DescribeInstances` permission
- Ensure you're using the correct region (specify with `--region`)

### "Failed to stop instance"
- Instance may be in a state that prevents stopping
- Check EC2 console for instance state
- Verify you have `ec2:StopInstances` permission

### "Failed to change instance type"
- Instance may not be stopped
- Instance type change may not be compatible
- Check AWS documentation for instance type compatibility

## License

MIT License

Copyright (c) 2025

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
