# env-to-ecs-yaml.sh

Convert `.env` file (or clipboard content) to ECS task-definition YAML `environment` block or Docker CLI `-e` flags.

## Prerequisites

- `pbpaste` (macOS), `xclip`, or `wl-paste` (Linux) — only needed for `-c` with no file argument (clipboard input).

## Usage

```
./env-to-ecs-yaml.sh [-c|--copy] [-d|--docker] [path-to-.env-file]
```

## Options

- `-c`, `--copy` — Output clean format without `START/END COPY HERE` markers (for piping to `pbcopy`). If no file is given, reads `.env` content from the clipboard instead of stdin/file, and writes converted output back to stdout (pipe to `pbcopy` to round-trip).
- `-d`, `--docker` — Output as Docker CLI `-e KEY="value" \` lines instead of ECS YAML.

## Input format

Standard `.env` lines: `KEY=value`. Blank lines and `#`-comments are skipped. Surrounding quotes on values are stripped.

## Output

- ECS YAML (default): `      - name: KEY` / `        value: "value"` under a `    environment:` header.
- Docker CLI (`-d`): `  -e KEY="value" \` per line.

Without `-c`, output is wrapped in `========== START/END COPY HERE ==========` markers with an info line. With `-c`, only the converted lines are printed (safe to pipe straight to `pbcopy`).

## Examples

```bash
./env-to-ecs-yaml.sh .env                # ECS YAML with markers
./env-to-ecs-yaml.sh -c .env | pbcopy    # ECS YAML clean, copied to clipboard
./env-to-ecs-yaml.sh -d .env             # Docker CLI with markers
./env-to-ecs-yaml.sh -d -c .env | pbcopy # Docker CLI clean, copied to clipboard
./env-to-ecs-yaml.sh -c | pbcopy         # read .env from clipboard, convert, write back to clipboard
./env-to-ecs-yaml.sh -c -d               # read .env from clipboard, print Docker CLI clean output
```

## Notes

- If no file is given and `-c` is not set, script prints usage and exits 1.
- If no file is given and clipboard is empty or no clipboard tool is found, script errors and exits 1.
