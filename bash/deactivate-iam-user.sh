#!/usr/bin/env bash

set -e
set -o pipefail

DRY_RUN=false

usage() {
    echo "Usage: $0 [--dry-run] <username>"
    echo ""
    echo "Options:"
    echo "  --dry-run    Show what would be done without making changes"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            USERNAME=$1
            shift
            ;;
    esac
done

if [ -z "$USERNAME" ]; then
    usage
fi

# Verify user exists
if ! aws iam get-user --user-name "$USERNAME" >/dev/null 2>&1; then
    echo "Error: User $USERNAME does not exist"
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would deactivate credentials for user: $USERNAME"
else
    # Confirmation prompt
    read -p "Are you sure you want to deactivate $USERNAME? (y/N) " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    echo "Deactivating credentials for user: $USERNAME"
fi

# Deactivate access keys
echo "Deactivating access keys..."
aws iam list-access-keys --user-name "$USERNAME" --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' --output text | tr '\t' '\n' | while read -r key_id; do
    if [ -n "$key_id" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] Would deactivate access key: $key_id"
        else
            aws iam update-access-key --user-name "$USERNAME" --access-key-id "$key_id" --status Inactive
            echo "Deactivated access key: $key_id"
        fi
    fi
done

# Deactivate MFA devices
echo "Deactivating MFA devices..."
aws iam list-mfa-devices --user-name "$USERNAME" --query 'MFADevices[].SerialNumber' --output text | tr '\t' '\n' | while read -r serial; do
    if [ -n "$serial" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] Would deactivate MFA device: $serial"
        else
            aws iam deactivate-mfa-device --user-name "$USERNAME" --serial-number "$serial"
            echo "Deactivated MFA device: $serial"
        fi
    fi
done

# Delete console password
echo "Deleting console password..."
if aws iam get-login-profile --user-name "$USERNAME" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would delete console password for user: $USERNAME"
    else
        aws iam delete-login-profile --user-name "$USERNAME"
        echo "Deleted console password for user: $USERNAME"
    fi
else
    echo "No console password found for user: $USERNAME"
fi

# Deactivate CodeCommit git credentials
echo "Deactivating CodeCommit git credentials..."
aws iam list-service-specific-credentials --user-name "$USERNAME" --service-name codecommit.amazonaws.com --query 'ServiceSpecificCredentials[?Status==`Active`].ServiceSpecificCredentialId' --output text | tr '\t' '\n' | while read -r cred_id; do
    if [ -n "$cred_id" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] Would deactivate git credential: $cred_id"
        else
            aws iam update-service-specific-credential --user-name "$USERNAME" --service-specific-credential-id "$cred_id" --status Inactive
            echo "Deactivated git credential: $cred_id"
        fi
    fi
done

# Delete SSH public keys for CodeCommit
echo "Deleting SSH public keys..."
aws iam list-ssh-public-keys --user-name "$USERNAME" --query 'SSHPublicKeys[].SSHPublicKeyId' --output text | tr '\t' '\n' | while read -r key_id; do
    if [ -n "$key_id" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] Would delete SSH public key: $key_id"
        else
            aws iam delete-ssh-public-key --user-name "$USERNAME" --ssh-public-key-id "$key_id"
            echo "Deleted SSH public key: $key_id"
        fi
    fi
done

# Delete signing certificates
echo "Deleting signing certificates..."
aws iam list-signing-certificates --user-name "$USERNAME" --query 'Certificates[].CertificateId' --output text | tr '\t' '\n' | while read -r cert_id; do
    if [ -n "$cert_id" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] Would delete signing certificate: $cert_id"
        else
            aws iam delete-signing-certificate --user-name "$USERNAME" --certificate-id "$cert_id"
            echo "Deleted signing certificate: $cert_id"
        fi
    fi
done

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Completed - no changes were made"
else
    echo "Completed deactivation for user: $USERNAME"
fi
