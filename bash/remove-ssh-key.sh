#!/bin/bash

# Remove a public SSH key from authorized_keys for a user on a remote host.
# Remote host is specified as an SSH config alias.
# Usage: ./remove-ssh-key.sh --host <ssh-alias> --key <key-file-or-string> [--user <remote-user>] [--dry-run]

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
            curl -s -H "Title: ${title}" -d "${message}" "ntfy.sh/${NTFY_TOPIC}" || true
        elif command -v wget &>/dev/null; then
            wget -qO- --header="Title: ${title}" --post-data="${message}" "ntfy.sh/${NTFY_TOPIC}" || true
        fi
    fi
}

die() {
    echo "Error: $*" >&2
    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$((end_time - START_TIME))
    echo "Time elapsed: ${elapsed}s"
    send_notification "remove-ssh-key: failed — $* (${elapsed}s)" "remove-ssh-key failed"
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") --host <ssh-alias> --key <key-file-or-string> [OPTIONS]

Remove a public SSH key from authorized_keys on a remote host.
No-op if the key is not present.
A timestamped backup of authorized_keys is created before any modification.

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
  # Remove key from the SSH login user's authorized_keys
  ./remove-ssh-key.sh --host myserver --key ~/.ssh/id_ed25519.pub

  # Remove key from a different user on the remote host (requires sudo)
  ./remove-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub

  # Dry run — shows whether key is present, makes no changes
  ./remove-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub --dry-run
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)    SSH_HOST="$2";    shift 2 ;;
        --user)    REMOTE_USER="$2"; shift 2 ;;
        --key)     KEY_INPUT="$2";   shift 2 ;;
        --dry-run) DRY_RUN=true;     shift   ;;
        -h|--help) usage; exit 0              ;;
        *) die "Unknown argument: $1"         ;;
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

# Basic sanity check
case "$PUBLIC_KEY" in
    ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-*|sk-ssh-*|ssh-dss\ *)
        : ;;
    *)
        die "Value does not look like a valid SSH public key: ${PUBLIC_KEY:0:40}..."
        ;;
esac

# ---------------------------------------------------------------------------
# Load .env if present
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    set -a; source "${SCRIPT_DIR}/.env"; set +a
fi

# ---------------------------------------------------------------------------
# Show plan
# ---------------------------------------------------------------------------

echo "=== remove-ssh-key ==="
echo "Host   : ${SSH_HOST}"
echo "User   : ${REMOTE_USER:-<ssh login user>}"
echo "Key    : ${PUBLIC_KEY:0:60}..."
echo "Dry run: ${DRY_RUN}"
echo ""

# ---------------------------------------------------------------------------
# Build remote script
# ---------------------------------------------------------------------------

# Branches on whether REMOTE_USER was specified (uses sudo) or not (direct write).
# Backup created before any modification. Removal uses grep -vF into a temp
# file then atomic move, preserving permissions and ownership.

build_remote_script() {
    local auth_keys_expr="$1"   # shell expression that resolves to auth_keys path
    local read_cmd="$2"         # prefix for read ops  (empty or "sudo")
    local write_cmd="$3"        # prefix for write ops (empty or "sudo")
    local chown_expr="$4"       # chown target (empty or "user:user")

    cat <<SCRIPT
set -e
KEY="${PUBLIC_KEY}"
AUTH_KEYS="${auth_keys_expr}"
BACKUP="\${AUTH_KEYS}.bak.\$(date +%s)"
TMP="\$(mktemp)"

if [ ! -f "\${AUTH_KEYS}" ]; then
    echo "authorized_keys not found at \${AUTH_KEYS} — nothing to do."
    rm -f "\${TMP}"
    exit 0
fi

if ! ${read_cmd} grep -qF "\${KEY}" "\${AUTH_KEYS}" 2>/dev/null; then
    echo "Key not present in \${AUTH_KEYS} — nothing to do."
    rm -f "\${TMP}"
    exit 0
fi

MATCHES=\$(${read_cmd} grep -cF "\${KEY}" "\${AUTH_KEYS}" || true)
echo "Found \${MATCHES} matching line(s) in \${AUTH_KEYS}."

if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY RUN] Would remove \${MATCHES} line(s). No changes made."
    rm -f "\${TMP}"
    exit 0
fi

# Backup, then remove matching lines
${read_cmd} cp "\${AUTH_KEYS}" "\${BACKUP}"
echo "Backup created: \${BACKUP}"

${read_cmd} grep -vF "\${KEY}" "\${AUTH_KEYS}" > "\${TMP}" || true
${write_cmd} cp "\${TMP}" "\${AUTH_KEYS}"
${write_cmd} chmod 600 "\${AUTH_KEYS}"
SCRIPT

    if [ -n "$chown_expr" ]; then
        echo "${write_cmd} chown ${chown_expr} \"\${AUTH_KEYS}\""
    fi

    cat <<SCRIPT
rm -f "\${TMP}"
echo "Key removed from \${AUTH_KEYS}."
SCRIPT
}

if [ -z "$REMOTE_USER" ]; then
    REMOTE_CMD=$(build_remote_script '${HOME}/.ssh/authorized_keys' "" "" "")
    echo "Connecting to ${SSH_HOST}..."
    ssh "$SSH_HOST" "$REMOTE_CMD"
else
    # Resolve target user's home dir on remote; all ops via sudo
    REMOTE_CMD=$(cat <<PREAMBLE
set -e
TARGET_USER="${REMOTE_USER}"
TARGET_HOME=\$(getent passwd "\${TARGET_USER}" 2>/dev/null | cut -d: -f6 || eval echo ~"\${TARGET_USER}")
PREAMBLE
)
    INNER=$(build_remote_script '${TARGET_HOME}/.ssh/authorized_keys' "sudo" "sudo" "${REMOTE_USER}:${REMOTE_USER}")
    REMOTE_CMD="${REMOTE_CMD}
${INNER}"
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

MSG="remove-ssh-key: key removed/verified for ${REMOTE_USER:-ssh-user} on ${SSH_HOST} (${ELAPSED}s)"
if [ -n "${NTFY_TOPIC:-}" ]; then
    if command -v curl &>/dev/null; then
        curl -s -H "Title: remove-ssh-key done" -d "$MSG" "ntfy.sh/${NTFY_TOPIC}" || true
    elif command -v wget &>/dev/null; then
        wget -qO- --header="Title: remove-ssh-key done" --post-data="$MSG" "ntfy.sh/${NTFY_TOPIC}" || true
    fi
fi
