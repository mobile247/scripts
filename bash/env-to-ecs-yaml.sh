#!/bin/bash

# Script to convert .env file to ECS YAML or Docker CLI format
# Usage: ./env-to-ecs-yaml.sh [-c|--copy] [-d|--docker] [path-to-.env-file]
# Options:
#   -c, --copy    Output clean format without markers (pipe to pbcopy).
#                 If no file given, reads .env content from clipboard instead.
#   -d, --docker  Output as Docker CLI parameters instead of ECS YAML

COPY_MODE=false
DOCKER_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--copy)
            COPY_MODE=true
            shift
            ;;
        -d|--docker)
            DOCKER_MODE=true
            shift
            ;;
        *)
            ENV_FILE="$1"
            shift
            ;;
    esac
done

if [ -z "$ENV_FILE" ] && [ "$COPY_MODE" = false ]; then
    echo "Usage: $0 [-c|--copy] [-d|--docker] [path-to-.env-file]"
    echo ""
    echo "Examples:"
    echo "  $0 .env                    # ECS YAML with markers"
    echo "  $0 -c .env | pbcopy        # ECS YAML clean (pipe to clipboard)"
    echo "  $0 -d .env                 # Docker CLI with markers"
    echo "  $0 -d -c .env | pbcopy     # Docker CLI clean (pipe to clipboard)"
    echo "  $0 -c                      # read .env content FROM clipboard, output clean"
    exit 1
fi

CLIPBOARD_INPUT=false
if [ -z "$ENV_FILE" ]; then
    CLIPBOARD_INPUT=true
    if command -v pbpaste &>/dev/null; then
        CLIP_CONTENT=$(pbpaste)
    elif command -v xclip &>/dev/null; then
        CLIP_CONTENT=$(xclip -selection clipboard -o)
    elif command -v wl-paste &>/dev/null; then
        CLIP_CONTENT=$(wl-paste)
    else
        echo "Error: no clipboard tool found (pbpaste/xclip/wl-paste)!"
        exit 1
    fi
    if [ -z "$CLIP_CONTENT" ]; then
        echo "Error: clipboard is empty!"
        exit 1
    fi
elif [ ! -f "$ENV_FILE" ]; then
    echo "Error: File '$ENV_FILE' not found!"
    exit 1
fi

# Show info messages only if not in copy mode
if [ "$COPY_MODE" = false ]; then
    if [ "$DOCKER_MODE" = true ]; then
        echo "Converting $ENV_FILE to Docker CLI format..."
    else
        echo "Converting $ENV_FILE to ECS YAML format..."
    fi
    echo ""
    echo "========== START COPY HERE =========="
fi

# Output format header
if [ "$DOCKER_MODE" = false ]; then
    echo "    environment:"
fi

# Process the .env file
first_line=true
while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and comments
    if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
        continue
    fi

    # Remove leading/trailing whitespace
    line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Extract key and value
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"

        # Remove quotes from value if present
        value=$(echo "$value" | sed -e 's/^["'\'']//' -e 's/["'\'']$//')

        if [ "$DOCKER_MODE" = true ]; then
            # Docker CLI format
            echo "  -e $key=\"$value\" \\"
        else
            # ECS YAML format
            echo "      - name: $key"
            echo "        value: \"$value\""
        fi
    fi
done < <(if [ "$CLIPBOARD_INPUT" = true ]; then printf '%s\n' "$CLIP_CONTENT"; else cat "$ENV_FILE"; fi)

# Show end marker only if not in copy mode
if [ "$COPY_MODE" = false ]; then
    echo "========== END COPY HERE =========="
fi
