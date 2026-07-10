#!/bin/bash

# Upsert a public SSH key in authorized_keys for a user on a remote host.
# Matches existing entries by key blob — replaces the full line if options/comment differ,
# appends if the key is absent. Handles keys with options prefixes (e.g. no-agent-forwarding,...).
# Usage: ./set-ssh-key.sh --host <ssh-alias> --key <key-file-or-string> [--user <remote-user>] [--dry-run]

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
    send_notification "set-ssh-key: failed — $* (${elapsed}s)" "set-ssh-key failed"
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") --host <ssh-alias> --key <key-file-or-string> [OPTIONS]

Upsert a public SSH key in authorized_keys on a remote host.
Matches by key blob — replaces the full line if options/comment differ, appends if absent.
Supports keys with options prefixes (e.g. no-agent-forwarding,permitopen="*:*" ssh-ed25519 ...).

Required:
  --host <ssh-alias>          SSH host alias from ~/.ssh/config (or user@host)
  --key  <file-or-string>     Path to a .pub file, or the full key string (with or without options)

Optional:
  --user <remote-user>        Target user on the remote host.
                              Defaults to the SSH login user (no sudo needed).
                              When set to a different user, sudo is used.
  --dry-run                   Show what would be done; do not modify anything
  -h, --help                  Show this help

Examples:
  # Set key with options
  ./set-ssh-key.sh --host myserver --key 'no-agent-forwarding,permitopen="*:*" ssh-ed25519 AAAA... user@host'

  # Set key from file (plain or with options)
  ./set-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub

  # Dry run
  ./set-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub --dry-run
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

# Extract the key blob (base64 field) — the field immediately after the key type.
# Works whether or not an options prefix is present.
KEY_BLOB=$(printf '%s' "$PUBLIC_KEY" | awk '{
    for (i = 1; i <= NF; i++) {
        if ($i == "ssh-rsa"    || $i == "ssh-ed25519" || $i == "ssh-dss" ||
            $i ~ /^ecdsa-sha2-/ || $i ~ /^sk-ssh-/ || $i ~ /^sk-ecdsa-/) {
            print $(i+1)
            exit
        }
    }
}')

[ -n "$KEY_BLOB" ] || die "Cannot extract key blob — does not look like a valid SSH public key: ${PUBLIC_KEY:0:60}..."

# Base64-encode the full key line to safely pass it through SSH without quoting issues.
# (Options prefix may contain characters like = " * that break shell embedding.)
KEY_B64=$(printf '%s' "$PUBLIC_KEY" | base64)

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

echo "=== set-ssh-key ==="
echo "Host   : ${SSH_HOST}"
echo "User   : ${REMOTE_USER:-<ssh login user>}"
echo "Key    : ${PUBLIC_KEY:0:80}..."
echo "Blob   : ${KEY_BLOB:0:40}..."
echo "Dry run: ${DRY_RUN}"
echo ""

# ---------------------------------------------------------------------------
# Build remote script
# ---------------------------------------------------------------------------

# Logic:
#   1. Decode full key line from base64 (avoids quoting issues with options like permitopen="*:*")
#   2. Search authorized_keys for any line containing the key blob
#   3a. If found and exact match — no-op
#   3b. If found but different (options/comment changed) — backup + replace line
#   3c. If not found — append
#
# Line replacement uses a bash read loop to avoid awk/sed escape issues with
# special characters in the replacement line.

build_remote_script() {
    local auth_keys_expr="$1"   # shell expression resolving to authorized_keys path
    local sudo_r="$2"           # prefix for read ops  (empty or "sudo")
    local sudo_w="$3"           # prefix for write ops (empty or "sudo")
    local chown_target="$4"     # chown arg (empty or "user:user")

    cat <<SCRIPT
set -e
FULL_KEY=\$(echo "${KEY_B64}" | base64 -d)
KEY_BLOB="${KEY_BLOB}"
AUTH_KEYS="${auth_keys_expr}"
DRY_RUN="${DRY_RUN}"

# Ensure authorized_keys exists
if ! ${sudo_r} test -f "\${AUTH_KEYS}"; then
    if [ "\${DRY_RUN}" = "true" ]; then
        echo "[DRY RUN] authorized_keys not found at \${AUTH_KEYS} — would create and append key."
        exit 0
    fi
    ${sudo_w} mkdir -p "\$(dirname "\${AUTH_KEYS}")"
    ${sudo_w} touch "\${AUTH_KEYS}"
    ${sudo_w} chmod 600 "\${AUTH_KEYS}"
$([ -n "$chown_target" ] && echo "    ${sudo_w} chown ${chown_target} \"\$(dirname \"\${AUTH_KEYS}\")\" \"\${AUTH_KEYS}\"")
    printf '%s\n' "\${FULL_KEY}" | ${sudo_w} tee -a "\${AUTH_KEYS}" > /dev/null
    echo "authorized_keys created and key appended."
    exit 0
fi

# Check current state
if ${sudo_r} grep -qF "\${KEY_BLOB}" "\${AUTH_KEYS}" 2>/dev/null; then
    if ${sudo_r} grep -qF "\${FULL_KEY}" "\${AUTH_KEYS}" 2>/dev/null; then
        echo "Key already present with matching options — no changes needed."
        exit 0
    fi
    # Key exists but with different options/comment — replace the line, preserving original options
    OLD_LINE=\$(${sudo_r} grep -F "\${KEY_BLOB}" "\${AUTH_KEYS}" | head -1)
    # Extract options prefix: everything before the key type field
    OLD_OPTIONS=\$(printf '%s' "\${OLD_LINE}" | awk '{
        for (i=1; i<=NF; i++) {
            if (\$i ~ /^ssh-/ || \$i ~ /^ecdsa-sha2-/ || \$i ~ /^sk-/) { break }
        }
        if (i > 1) { for (j=1; j<i; j++) printf "%s%s", \$j, (j<i-1 ? " " : "") }
    }')
    if [ -n "\${OLD_OPTIONS}" ]; then
        REPLACEMENT_LINE="\${OLD_OPTIONS} \${FULL_KEY}"
    else
        REPLACEMENT_LINE="\${FULL_KEY}"
    fi
    if [ "\${DRY_RUN}" = "true" ]; then
        echo "[DRY RUN] Would replace existing line (preserving options):"
        echo "  OLD: \${OLD_LINE}"
        echo "  NEW: \${REPLACEMENT_LINE}"
        exit 0
    fi
    BACKUP="\${AUTH_KEYS}.bak.\$(date +%s)"
    ${sudo_r} cp "\${AUTH_KEYS}" "\${BACKUP}"
    echo "Backup created: \${BACKUP}"
    TMP=\$(mktemp)
    # Read loop: replace any line containing the key blob with the new full line
    REPLACED=0
    while IFS= read -r line || [ -n "\$line" ]; do
        if printf '%s' "\$line" | grep -qF "\${KEY_BLOB}"; then
            printf '%s\n' "\${REPLACEMENT_LINE}"
            REPLACED=\$((REPLACED + 1))
        else
            printf '%s\n' "\$line"
        fi
    done < <(${sudo_r} cat "\${AUTH_KEYS}") > "\${TMP}"
    ${sudo_w} cp "\${TMP}" "\${AUTH_KEYS}"
    ${sudo_w} chmod 600 "\${AUTH_KEYS}"
$([ -n "$chown_target" ] && echo "    ${sudo_w} chown ${chown_target} \"\${AUTH_KEYS}\"")
    rm -f "\${TMP}"
    echo "Replaced \${REPLACED} line(s) in \${AUTH_KEYS}."
else
    # Key blob not present — check if an entry with matching comment exists (key rotation)
    KEY_COMMENT=\$(printf '%s' "\${FULL_KEY}" | awk '{print \$NF}')
    COMMENT_LINE=\$(${sudo_r} awk -v c="\${KEY_COMMENT}" '\$NF == c' "\${AUTH_KEYS}" 2>/dev/null | head -1 || true)
    # Determine match target: prefer comment match, fall back to key-type match
    MATCH_LINE=""
    MATCH_BY=""
    if [ -n "\${KEY_COMMENT}" ] && [ -n "\${COMMENT_LINE}" ]; then
        MATCH_LINE="\${COMMENT_LINE}"
        MATCH_BY="comment"
    else
        # Extract key type from new key (e.g. ssh-ed25519)
        KEY_TYPE=\$(printf '%s' "\${FULL_KEY}" | awk '{
            for (i=1; i<=NF; i++) {
                if (\$i ~ /^ssh-/ || \$i ~ /^ecdsa-sha2-/ || \$i ~ /^sk-/) { print \$i; exit }
            }
        }')
        TYPE_LINE=\$(${sudo_r} awk -v t="\${KEY_TYPE}" '{
            for (i=1; i<=NF; i++) { if (\$i == t) { print; exit } }
        }' "\${AUTH_KEYS}" 2>/dev/null | head -1 || true)
        if [ -n "\${KEY_TYPE}" ] && [ -n "\${TYPE_LINE}" ]; then
            MATCH_LINE="\${TYPE_LINE}"
            MATCH_BY="key-type (\${KEY_TYPE})"
        fi
    fi

    if [ -n "\${MATCH_LINE}" ]; then
        # Replace matched entry, preserving its options
        OLD_OPTIONS=\$(printf '%s' "\${MATCH_LINE}" | awk '{
            for (i=1; i<=NF; i++) {
                if (\$i ~ /^ssh-/ || \$i ~ /^ecdsa-sha2-/ || \$i ~ /^sk-/) { break }
            }
            if (i > 1) { for (j=1; j<i; j++) printf "%s%s", \$j, (j<i-1 ? " " : "") }
        }')
        if [ -n "\${OLD_OPTIONS}" ]; then
            REPLACEMENT_LINE="\${OLD_OPTIONS} \${FULL_KEY}"
        else
            REPLACEMENT_LINE="\${FULL_KEY}"
        fi
        if [ "\${DRY_RUN}" = "true" ]; then
            echo "[DRY RUN] Found entry by \${MATCH_BY} — would replace (preserving options):"
            echo "  OLD: \${MATCH_LINE}"
            echo "  NEW: \${REPLACEMENT_LINE}"
            exit 0
        fi
        BACKUP="\${AUTH_KEYS}.bak.\$(date +%s)"
        ${sudo_r} cp "\${AUTH_KEYS}" "\${BACKUP}"
        echo "Backup created: \${BACKUP}"
        TMP=\$(mktemp)
        REPLACED=0
        while IFS= read -r line || [ -n "\$line" ]; do
            if [ "\$line" = "\${MATCH_LINE}" ]; then
                printf '%s\n' "\${REPLACEMENT_LINE}"
                REPLACED=\$((REPLACED + 1))
            else
                printf '%s\n' "\$line"
            fi
        done < <(${sudo_r} cat "\${AUTH_KEYS}") > "\${TMP}"
        ${sudo_w} cp "\${TMP}" "\${AUTH_KEYS}"
        ${sudo_w} chmod 600 "\${AUTH_KEYS}"
$([ -n "$chown_target" ] && echo "        ${sudo_w} chown ${chown_target} \"\${AUTH_KEYS}\"")
        rm -f "\${TMP}"
        echo "Replaced \${REPLACED} line(s) in \${AUTH_KEYS} (matched by \${MATCH_BY})."
    else
        # No match by blob, comment, or key type — append
        if [ "\${DRY_RUN}" = "true" ]; then
            echo "[DRY RUN] Key not present — would append:"
            echo "  \${FULL_KEY}"
            exit 0
        fi
        printf '%s\n' "\${FULL_KEY}" | ${sudo_w} tee -a "\${AUTH_KEYS}" > /dev/null
        echo "Key appended to \${AUTH_KEYS}."
    fi
fi
SCRIPT
}

if [ -z "$REMOTE_USER" ]; then
    REMOTE_CMD=$(build_remote_script '${HOME}/.ssh/authorized_keys' "" "" "")
    echo "Connecting to ${SSH_HOST}..."
    ssh "$SSH_HOST" "$REMOTE_CMD"
else
    PREAMBLE=$(cat <<PREAMBLE
set -e
TARGET_USER="${REMOTE_USER}"
TARGET_HOME=\$(getent passwd "\${TARGET_USER}" 2>/dev/null | cut -d: -f6 || eval echo ~"\${TARGET_USER}")
PREAMBLE
)
    INNER=$(build_remote_script '${TARGET_HOME}/.ssh/authorized_keys' "sudo" "sudo" "${REMOTE_USER}:${REMOTE_USER}")
    REMOTE_CMD="${PREAMBLE}
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

MSG="set-ssh-key: key set for ${REMOTE_USER:-ssh-user} on ${SSH_HOST} (${ELAPSED}s)"
if [ -n "${NTFY_TOPIC:-}" ]; then
    if command -v curl &>/dev/null; then
        curl -s -H "Title: set-ssh-key done" -d "$MSG" "ntfy.sh/${NTFY_TOPIC}" || true
    elif command -v wget &>/dev/null; then
        wget -qO- --header="Title: set-ssh-key done" --post-data="$MSG" "ntfy.sh/${NTFY_TOPIC}" || true
    fi
fi
