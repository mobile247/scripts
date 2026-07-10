# copy-target-group.sh

Clone an AWS ALB/NLB target group — protocol, port, VPC, target type, health check config, attributes, tags, and registered targets — into a new target group.

## Prerequisites

- `aws` CLI installed and configured (credentials/profile with `elasticloadbalancing:*` read/write permissions)
- `jq`

## Usage

```bash
./copy-target-group.sh <source-target-group-name> <new-target-group-name> [vpc-id]
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `source-target-group-name` | Yes | Name of the existing target group to copy |
| `new-target-group-name` | Yes | Name for the new target group |
| `vpc-id` | No | VPC for the new target group (defaults to the source target group's VPC) |

## What It Does

1. Looks up the source target group by name and fetches its full configuration
2. Creates a new target group with the same protocol, port, target type, and health check settings
3. Copies target group attributes (excluding `load_balancing.cross_zone.enabled`)
4. Copies tags
5. Registers the same targets (healthy, unhealthy, or initial state) from the source group

## Output and Side Effects

- Creates a new AWS target group and registers targets/tags/attributes on it — this is a live AWS write operation, no dry-run mode
- Prints elapsed time on exit
- Sends an ntfy notification if `NTFY_TOPIC` is set (success or failure)
- Does **not** update any load balancer listeners to point at the new target group — this must be done manually afterward
- Does **not** delete the source target group

## Environment Variables

| Variable | Description |
|----------|-------------|
| `NTFY_TOPIC` | Optional. Send result notification via ntfy.sh |

## Example

```bash
./copy-target-group.sh my-old-tg my-new-tg vpc-12345678
```

## Notes

- After running, manually update ALB/NLB listener rules to point to the new target group, verify target health, and delete the old target group when no longer needed (the script prints these reminders on completion).
- No `--dry-run` support — review the source target group configuration before running.
