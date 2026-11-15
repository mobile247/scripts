#!/bin/zsh

START_TIME=$(date +%s)

# Load .env from the current working directory if present; otherwise fall back to the environment
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

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

TOTAL=0
FAILED=()

for dir in ~/.pyenv/versions/*(/N); do
  version=${dir:t}
  if [[ -x "$dir/bin/python" ]]; then
    TOTAL=$((TOTAL + 1))
    out=~/.pyenv/${version}-python-packages.txt
    # Write to a temp file first so a failed freeze never clobbers the last good snapshot
    if "$dir/bin/python" -m pip freeze > "${out}.tmp"; then
      mv "${out}.tmp" "$out"
    else
      rm -f "${out}.tmp"
      FAILED+=("$version")
      echo "ERROR: pip freeze failed for ${version}" >&2
    fi
  fi
done

if (( ${#FAILED} > 0 )); then
  EXIT_CODE=1
  RESULT="failure (exit ${EXIT_CODE}) - ${#FAILED}/${TOTAL} failed: ${FAILED[*]}"
else
  EXIT_CODE=0
  RESULT="success - ${TOTAL} version(s) frozen"
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo "$(date '+%Y-%m-%d %H:%M:%S') ${RESULT}"
echo "Time elapsed: ${ELAPSED}s"

if [[ -n "${NTFY_TOPIC:-}" ]]; then
  MSG="freeze-pyenv-packages: ${RESULT} (${ELAPSED}s)"
  ntfy_publish "Script Done" "$MSG"
fi

exit $EXIT_CODE
