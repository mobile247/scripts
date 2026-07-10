# rotate-ssh-key.sh

Rotate an SSH public key for a user across one or more remote hosts. Removes the old key then appends the new key on each host. Delegates to `remove-ssh-key.sh` and `add-ssh-key.sh`.

---

## Prerequisites

- `remove-ssh-key.sh` and `add-ssh-key.sh` must be in the same directory and executable
- SSH access to each target host (via `~/.ssh/config` alias or `user@host`)
- Sufficient privileges on each remote host to modify the target user's `authorized_keys` (sudo is used automatically when `--user` differs from the SSH login user)

---

## Usage

```bash
./rotate-ssh-key.sh --user <user> --old-key <file> --new-key <file> \
    --host <host1> [--host <host2> ...] [--dry-run]
```

---

## Parameters

| Flag | Required | Description |
|------|----------|-------------|
| `--user <remote-user>` | Yes | Target user on each remote host |
| `--old-key <file-or-string>` | Yes | Old public key to remove (`.pub` file path or raw key string) |
| `--new-key <file-or-string>` | Yes | New public key to add (`.pub` file path or raw key string) |
| `--host <ssh-alias>` | Yes (≥1) | SSH host alias; repeat once per host |
| `--dry-run` | No | Print what would be done; no changes made |
| `-h`, `--help` | No | Show usage |

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `NTFY_TOPIC` | If set, sends a notification on completion or failure |

Loaded from `.env` in the script directory if present.

---

## Behaviour

1. Iterates hosts in order.
2. Per host: runs `remove-ssh-key.sh` (removes old key), then `add-ssh-key.sh` (appends new key).
3. If either step fails on a host, logs a warning, records the failure, and continues to the next host.
4. Exits non-zero if any host failed.
5. A timestamped backup of `authorized_keys` is created by `remove-ssh-key.sh` before any modification.

---

## Usage Examples

```bash
# Rotate key on a single host
./rotate-ssh-key.sh --user johndoe --old-key old.pub --new-key new.pub --host server1

# Rotate across multiple hosts
./rotate-ssh-key.sh --user johndoe --old-key old.pub --new-key new.pub \
    --host server1 --host server2 --host server3

# Dry run first
./rotate-ssh-key.sh --user johndoe --old-key old.pub --new-key new.pub \
    --host server1 --host server2 --dry-run
```

---

## Security Notes

- The old key is removed before the new key is added. There is a brief window per host where neither key exists in `authorized_keys`. Ensure the user is not actively connected during rotation if continuity is required.
- `remove-ssh-key.sh` creates a timestamped backup before modifying `authorized_keys`. Backup location: `~<user>/.ssh/authorized_keys.bak.<timestamp>`.
- No keys are logged or stored locally beyond what is passed as arguments.
