#!/bin/bash

# Append a public SSH key to authorized_keys for a user on a remote host.
# Remote host is specified as an SSH config alias.
# Usage: ./add-ssh-key.sh --host <ssh-alias> --key <key-file-or-string> [--user <remote-user>] [--dry-run]

set -e
set -o pipefail

START_TIME=$(date +%s)
DRY_RUN=false
SSH_HOST=""
REMOTE_USER=""
KEY_INPUT=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

send_notification() {
    local message="$1"
    local title="$2"
    if [ -n "${NTFY_TOPIC:-}" ]; then
        if command -v curl &>/dev/null; then
            curl -s -H "Title: ${title}" -d "${message}" "https://ntfy.sh/${NTFY_TOPIC}" || true
        elif command -v wget &>/dev/null; then
            wget -qO- --header="Title: ${title}" --post-data="${message}" "https://ntfy.sh/${NTFY_TOPIC}" || true
        fi
    fi
}

show_elapsed() {
    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$((end_time - START_TIME))
    echo "Time elapsed: ${elapsed}s"
    echo "$elapsed"
}

die() {
    echo "Error: $*" >&2
    local elapsed
    elapsed=$(show_elapsed)
    send_notification "add-ssh-key: failed — $* (${elapsed}s)" "add-ssh-key failed"
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") --host <ssh-alias> --key <key-file-or-string> [OPTIONS]

Append a public SSH key to authorized_keys on a remote host.
Duplicate keys are detected and skipped (idempotent).

Required:
  --host <ssh-alias>          SSH host alias from ~/.ssh/config (or user@host)
  --key  <file-or-string>     Path to a .pub file, or the key string directly

Optional:
  --user <remote-user>        Target user on the remote host.
                              Defaults to the SSH login user (no sudo needed).
                              When set to a different user, sudo is used.
  --dry-run                   Show what would be done; do not modify anything
  -h, --help                  Show this help

Examples:
  # Add key to the SSH login user's authorized_keys
  ./add-ssh-key.sh --host myserver --key ~/.ssh/id_ed25519.pub

  # Add key to a different user on the remote host (requires sudo)
  ./add-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub

  # Pass the key inline
  ./add-ssh-key.sh --host myserver --key "ssh-ed25519 AAAAC3Nz... user@laptop"

  # Dry run
  ./add-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub --dry-run
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)   SSH_HOST="$2";    shift 2 ;;
        --user)   REMOTE_USER="$2"; shift 2 ;;
        --key)    KEY_INPUT="$2";   shift 2 ;;
        --dry-run) DRY_RUN=true;    shift   ;;
        -h|--help) usage; exit 0             ;;
        *) die "Unknown argument: $1"        ;;
    esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

[ -n "$SSH_HOST" ] || die "--host is required"
[ -n "$KEY_INPUT" ] || die "--key is required"

# Resolve key: file path or inline string
if [ -f "$KEY_INPUT" ]; then
    PUBLIC_KEY=$(cat "$KEY_INPUT")
else
    PUBLIC_KEY="$KEY_INPUT"
fi

# Basic sanity check: should look like an SSH public key
case "$PUBLIC_KEY" in
    ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-*|sk-ssh-*|ssh-dss\ *)
        : ;;
    *)
        die "Value does not look like a valid SSH public key: ${PUBLIC_KEY:0:40}..."
        ;;
esac

# The key ends up in a remote shell script, so require a single well-formed key.
# (ssh-keygen accepts arbitrary comments — the key is also base64-encoded below.)
[ "$(printf '%s\n' "$PUBLIC_KEY" | wc -l)" -eq 1 ] || die "Key must be a single line"
printf '%s\n' "$PUBLIC_KEY" | ssh-keygen -l -f - >/dev/null 2>&1 \
    || die "ssh-keygen could not parse key: ${PUBLIC_KEY:0:40}..."

if [ -n "$REMOTE_USER" ] && ! [[ "$REMOTE_USER" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]]; then
    die "Invalid --user value: ${REMOTE_USER}"
fi

# Base64 alphabet has no shell metacharacters, so it can be single-quoted safely
# inside the remote script; the raw key is never embedded.
KEY_B64=$(printf '%s' "$PUBLIC_KEY" | base64 | tr -d '\n')

# ---------------------------------------------------------------------------
# Load .env if present
# ---------------------------------------------------------------------------

if [ -f .env ]; then
    # shellcheck disable=SC1091
    set -a; source .env; set +a
fi

# ---------------------------------------------------------------------------
# Show plan
# ---------------------------------------------------------------------------

echo "=== add-ssh-key ==="
echo "Host  : ${SSH_HOST}"
echo "User  : ${REMOTE_USER:-<ssh login user>}"
echo "Key   : ${PUBLIC_KEY:0:60}..."
echo "Dry run: ${DRY_RUN}"
echo ""

if $DRY_RUN; then
    echo "[DRY RUN] Would run remote script on ${SSH_HOST}:"
    if [ -n "$REMOTE_USER" ]; then
        echo "  sudo -u '${REMOTE_USER}' append key to ~${REMOTE_USER}/.ssh/authorized_keys"
    else
        echo "  append key to ~/.ssh/authorized_keys (SSH login user)"
    fi
    echo ""
    echo "[DRY RUN] No changes made."
    elapsed=$(show_elapsed)
    send_notification "add-ssh-key: dry run on ${SSH_HOST} (${elapsed}s)" "add-ssh-key dry run"
    exit 0
fi

# ---------------------------------------------------------------------------
# Build remote script
# ---------------------------------------------------------------------------

# The key is passed base64-encoded and decoded remotely (never embedded raw).
# Remote variables use escaped $ to prevent local expansion.
# We branch on whether a specific REMOTE_USER was requested:
#   - No user:   write directly to current user's ~/.ssh/authorized_keys
#   - With user: resolve home dir, write via sudo -u <user>

if [ -z "$REMOTE_USER" ]; then
    REMOTE_CMD=$(cat <<SCRIPT
set -e
KEY=\$(printf '%s' '${KEY_B64}' | base64 -d)
AUTH_KEYS="\${HOME}/.ssh/authorized_keys"
mkdir -p "\${HOME}/.ssh"
chmod 700 "\${HOME}/.ssh"
touch "\${AUTH_KEYS}"
chmod 600 "\${AUTH_KEYS}"
if grep -qF "\${KEY}" "\${AUTH_KEYS}" 2>/dev/null; then
    echo "Key already present in \${AUTH_KEYS} — no changes made."
else
    printf '%s\n' "\${KEY}" >> "\${AUTH_KEYS}"
    echo "Key appended to \${AUTH_KEYS}."
fi
SCRIPT
)
    echo "Connecting to ${SSH_HOST}..."
    ssh "$SSH_HOST" "$REMOTE_CMD"
else
    REMOTE_CMD=$(cat <<SCRIPT
set -e
KEY=\$(printf '%s' '${KEY_B64}' | base64 -d)
TARGET_USER="${REMOTE_USER}"
TARGET_HOME=\$(getent passwd "\${TARGET_USER}" 2>/dev/null | cut -d: -f6 || eval echo ~"\${TARGET_USER}")
AUTH_KEYS="\${TARGET_HOME}/.ssh/authorized_keys"
sudo mkdir -p "\${TARGET_HOME}/.ssh"
sudo chmod 700 "\${TARGET_HOME}/.ssh"
sudo chown "\${TARGET_USER}:\${TARGET_USER}" "\${TARGET_HOME}/.ssh"
sudo touch "\${AUTH_KEYS}"
sudo chmod 600 "\${AUTH_KEYS}"
sudo chown "\${TARGET_USER}:\${TARGET_USER}" "\${AUTH_KEYS}"
if sudo grep -qF "\${KEY}" "\${AUTH_KEYS}" 2>/dev/null; then
    echo "Key already present in \${AUTH_KEYS} — no changes made."
else
    printf '%s\n' "\${KEY}" | sudo tee -a "\${AUTH_KEYS}" > /dev/null
    echo "Key appended to \${AUTH_KEYS}."
fi
SCRIPT
)
    echo "Connecting to ${SSH_HOST} (will use sudo for user '${REMOTE_USER}')..."
    ssh "$SSH_HOST" "$REMOTE_CMD"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo ""
echo "Time elapsed: ${ELAPSED}s"

MSG="add-ssh-key: key added/verified for ${REMOTE_USER:-ssh-user} on ${SSH_HOST} (${ELAPSED}s)"
if [ -n "${NTFY_TOPIC:-}" ]; then
    if command -v curl &>/dev/null; then
        curl -s -H "Title: add-ssh-key done" -d "$MSG" "https://ntfy.sh/${NTFY_TOPIC}" || true
    elif command -v wget &>/dev/null; then
        wget -qO- --header="Title: add-ssh-key done" --post-data="$MSG" "https://ntfy.sh/${NTFY_TOPIC}" || true
    fi
fi
