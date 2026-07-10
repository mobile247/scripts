# restart-instance.sh

Stop and start an EC2 instance by its `Name` tag. If multiple instances share the same name, prompts interactively to pick one.

## Prerequisites

- `aws` CLI installed and configured (credentials/profile with EC2 describe/stop/start permissions)

## Usage

```bash
./restart-instance.sh <instance-name>
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `instance-name` | Yes | Value of the instance's `Name` tag to search for |

## What It Does

1. Searches for instances (running, stopped, stopping, or pending) matching the given `Name` tag
2. If exactly one match, selects it automatically; if multiple, prints a table and prompts for a selection index
3. If the instance is already stopped, starts it directly
4. If running, stops it (waiting up to 300s, with an optional force-stop prompt on timeout), then starts it
5. Reports the instance's new private IP after restart (may change on restart)

## Output and Side Effects

- Live AWS write operation (stop/start) — no dry-run mode
- Interactive prompts: instance selection (if multiple matches) and optional force-stop confirmation on timeout
- Prints total execution time on exit
- Sends an ntfy notification if `NTFY_TOPIC` is set (success or failure)

## Environment Variables

| Variable | Description |
|----------|-------------|
| `NTFY_TOPIC` | Optional. Send result notification via ntfy.sh |

## Example

```bash
./restart-instance.sh my-web-server
```

## Notes

- Only instances already in `running` or `stopped` state can be restarted; other states (e.g. `terminated`) cause the script to exit with an error.
- No `--dry-run` support — this script always performs the stop/start operation.
- Private IP may change after restart unless the instance has an Elastic IP.
