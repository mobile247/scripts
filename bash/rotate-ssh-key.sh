#!/bin/bash

# Rotate an SSH public key for a user across one or more remote hosts.
# Removes the old key and appends the new key in sequence per host.
# Delegates to remove-ssh-key.sh and add-ssh-key.sh in the same directory.
#
# Usage: ./rotate-ssh-key.sh --user <user> --old-key <file> --new-key <file> --host <host> [--host <host> ...] [--dry-run]

set -e
set -o pipefail

START_TIME=$(date +%s)

REMOTE_USER=""
OLD_KEY_INPUT=""
NEW_KEY_INPUT=""
HOSTS=()
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOVE_SCRIPT="${SCRIPT_DIR}/remove-ssh-key"
ADD_SCRIPT="${SCRIPT_DIR}/add-ssh-key"

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
    send_notification "rotate-ssh-key: failed — $* (${elapsed}s)" "rotate-ssh-key failed"
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") --user <user> --old-key <file> --new-key <file> --host <host> [--host <host> ...] [OPTIONS]

Rotate an SSH public key for a user across one or more remote hosts.
Removes the old key then appends the new key on each host.

Required:
  --user     <remote-user>      Target user on each remote host (uses sudo)
  --old-key  <file-or-string>   Old public key to remove (.pub file or key string)
  --new-key  <file-or-string>   New public key to add (.pub file or key string)
  --host     <ssh-alias>        SSH host alias (repeatable; specify once per host)

Optional:
  --dry-run                     Show what would be done; do not modify anything
  -h, --help                    Show this help

Examples:
  # Rotate key on a single host
  $(basename "$0") --user johndoe --old-key old.pub --new-key new.pub --host server1

  # Rotate across multiple hosts
  $(basename "$0") --user johndoe --old-key old.pub --new-key new.pub \\
      --host server1 --host server2 --host server3

  # Dry run
  $(basename "$0") --user johndoe --old-key old.pub --new-key new.pub --host server1 --dry-run
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)     REMOTE_USER="$2";    shift 2 ;;
        --old-key)  OLD_KEY_INPUT="$2";  shift 2 ;;
        --new-key)  NEW_KEY_INPUT="$2";  shift 2 ;;
        --host)     HOSTS+=("$2");       shift 2 ;;
        --dry-run)  DRY_RUN=true;        shift   ;;
        -h|--help)  usage; exit 0                 ;;
        *) die "Unknown argument: $1"             ;;
    esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

[ -n "$REMOTE_USER" ]    || die "--user is required"
[ -n "$OLD_KEY_INPUT" ]  || die "--old-key is required"
[ -n "$NEW_KEY_INPUT" ]  || die "--new-key is required"
[ ${#HOSTS[@]} -gt 0 ]   || die "at least one --host is required"

[ -x "$REMOVE_SCRIPT" ]  || die "remove-ssh-key.sh not found or not executable: ${REMOVE_SCRIPT}"
[ -x "$ADD_SCRIPT" ]     || die "add-ssh-key.sh not found or not executable: ${ADD_SCRIPT}"

# ---------------------------------------------------------------------------
# Load .env if present
# ---------------------------------------------------------------------------

if [ -f "${SCRIPT_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    set -a; source "${SCRIPT_DIR}/.env"; set +a
fi

# ---------------------------------------------------------------------------
# Show plan
# ---------------------------------------------------------------------------

echo "=== rotate-ssh-key ==="
echo "User     : ${REMOTE_USER}"
echo "Old key  : ${OLD_KEY_INPUT}"
echo "New key  : ${NEW_KEY_INPUT}"
echo "Hosts    : ${HOSTS[*]}"
echo "Dry run  : ${DRY_RUN}"
echo ""

# ---------------------------------------------------------------------------
# Rotate per host
# ---------------------------------------------------------------------------

DRY_FLAG=""
$DRY_RUN && DRY_FLAG="--dry-run"

FAILED_HOSTS=()

for host in "${HOSTS[@]}"; do
    echo "--- ${host} ---"

    echo "[1/2] Removing old key from ${host}..."
    if ! "$REMOVE_SCRIPT" --host "$host" --user "$REMOTE_USER" --key "$OLD_KEY_INPUT" ${DRY_FLAG:+"$DRY_FLAG"}; then
        echo "Warning: remove step failed on ${host}" >&2
        FAILED_HOSTS+=("${host}(remove)")
        continue
    fi

    echo "[2/2] Adding new key to ${host}..."
    if ! "$ADD_SCRIPT" --host "$host" --user "$REMOTE_USER" --key "$NEW_KEY_INPUT" ${DRY_FLAG:+"$DRY_FLAG"}; then
        echo "Warning: add step failed on ${host}" >&2
        FAILED_HOSTS+=("${host}(add)")
        continue
    fi

    echo "Rotation complete on ${host}."
    echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
if [ ${#FAILED_HOSTS[@]} -eq 0 ]; then
    RESULT="success — rotated on ${#HOSTS[@]} host(s)"
    echo "All hosts done. Time elapsed: ${ELAPSED}s"
    send_notification "rotate-ssh-key: ${REMOTE_USER} ${RESULT} (${ELAPSED}s)" "rotate-ssh-key done"
else
    RESULT="partial failure — failed: ${FAILED_HOSTS[*]}"
    echo "Completed with errors. Failed: ${FAILED_HOSTS[*]}"
    echo "Time elapsed: ${ELAPSED}s"
    send_notification "rotate-ssh-key: ${REMOTE_USER} ${RESULT} (${ELAPSED}s)" "rotate-ssh-key partial"
    exit 1
fi
