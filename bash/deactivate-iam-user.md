# Deactivate IAM User

Deactivates all credentials for an AWS IAM user without deleting the user account. Useful for offboarding employees or disabling compromised accounts while preserving audit history.

## Usage

```bash
./deactivate-iam-user.sh [--dry-run] <username>
```

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Show what would be done without making changes |

## What It Does

The script disables or removes the following credential types:

| Credential Type | Action |
|-----------------|--------|
| Access Keys | Deactivated (set to Inactive) |
| MFA Devices | Deactivated |
| Console Password | Deleted |
| CodeCommit Git Credentials | Deactivated |
| SSH Public Keys | Deleted |
| Signing Certificates | Deleted |

## Prerequisites

- AWS CLI installed and configured
- IAM permissions to manage user credentials:
  - `iam:GetUser`
  - `iam:ListAccessKeys`
  - `iam:UpdateAccessKey`
  - `iam:ListMFADevices`
  - `iam:DeactivateMFADevice`
  - `iam:GetLoginProfile`
  - `iam:DeleteLoginProfile`
  - `iam:ListServiceSpecificCredentials`
  - `iam:UpdateServiceSpecificCredential`
  - `iam:ListSSHPublicKeys`
  - `iam:DeleteSSHPublicKey`
  - `iam:ListSigningCertificates`
  - `iam:DeleteSigningCertificate`

## Examples

### Dry run

```bash
$ ./deactivate-iam-user.sh --dry-run john.doe
[DRY RUN] Would deactivate credentials for user: john.doe
Deactivating access keys...
[DRY RUN] Would deactivate access key: AKIAIOSFODNN7EXAMPLE
Deactivating MFA devices...
[DRY RUN] Would deactivate MFA device: arn:aws:iam::123456789012:mfa/john.doe
Deleting console password...
[DRY RUN] Would delete console password for user: john.doe
Deactivating CodeCommit git credentials...
Deleting SSH public keys...
Deleting signing certificates...
[DRY RUN] Completed - no changes were made
```

### Actual deactivation

```bash
$ ./deactivate-iam-user.sh john.doe
Are you sure you want to deactivate john.doe? (y/N) y
Deactivating credentials for user: john.doe
Deactivating access keys...
Deactivated access key: AKIAIOSFODNN7EXAMPLE
Deactivating MFA devices...
Deactivated MFA device: arn:aws:iam::123456789012:mfa/john.doe
Deleting console password...
Deleted console password for user: john.doe
Deactivating CodeCommit git credentials...
Deleting SSH public keys...
Deleting signing certificates...
Completed deactivation for user: john.doe
```

## Notes

- The script requires confirmation before proceeding (skipped in dry-run mode)
- The user account itself is not deleted, only credentials are disabled
- Access keys and CodeCommit credentials are deactivated rather than deleted, allowing for potential reactivation
- Group memberships and attached policies are not modified
