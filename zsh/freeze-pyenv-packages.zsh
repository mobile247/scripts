#!/bin/zsh

START_TIME=$(date +%s)

# Load .env from the current working directory if present; otherwise fall back to the environment
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

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
  if command -v curl &>/dev/null; then
    curl -s -H "Title: Script Done" -d "$MSG" "ntfy.sh/${NTFY_TOPIC}" >/dev/null || true
  elif command -v wget &>/dev/null; then
    wget -qO- --post-data="$MSG" --header="Title: Script Done" "ntfy.sh/${NTFY_TOPIC}" >/dev/null || true
  fi
fi

exit $EXIT_CODE
