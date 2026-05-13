# remove-ssh-key.sh

Remove a public SSH key from `authorized_keys` for a specified user on a remote host. Idempotent — no-op if the key is not present. A timestamped backup of `authorized_keys` is created before any modification.

---

## Prerequisites

- `ssh` client installed locally
- SSH host alias configured in `~/.ssh/config`, or a plain `user@host` string
- Passwordless SSH access to the remote host (key-based auth)
- If `--user` targets a different account than the SSH login user: `sudo` privileges on the remote host

---

## Usage

```bash
./remove-ssh-key.sh --host <ssh-alias> --key <key-file-or-string> [--user <remote-user>] [--dry-run]
```

---

## Options

| Flag | Required | Description |
|------|----------|-------------|
| `--host` | Yes | SSH host alias from `~/.ssh/config`, or `user@host` |
| `--key` | Yes | Path to a `.pub` file, or the key string directly |
| `--user` | No | Target user on the remote host. Defaults to the SSH login user (no sudo). When set to a different user, `sudo` is used. |
| `--dry-run` | No | Show whether key is present and what would be removed; make no changes |
| `-h`, `--help` | No | Show usage |

---

## Examples

```bash
# Remove key from the SSH login user
./remove-ssh-key.sh --host myserver --key ~/.ssh/id_ed25519.pub

# Remove key from a different user (requires sudo)
./remove-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub

# Pass the key as an inline string
./remove-ssh-key.sh --host myserver --key "ssh-ed25519 AAAAC3Nz... user@laptop"

# Dry run — reports presence, makes no changes
./remove-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub --dry-run
```

---

## Behavior

1. Resolves `--key` to a key string (reads file if path given; validates format).
2. SSHes to `--host`.
3. Checks if `authorized_keys` exists. If not, exits cleanly.
4. Checks if the key is present (`grep -qF`). If not, exits cleanly.
5. Creates a timestamped backup: `authorized_keys.bak.<unix-timestamp>`.
6. Removes all matching lines via `grep -vF` into a temp file, then replaces the original.
7. Restores `600` permissions (and correct ownership when `--user` is set).
8. When `--user` differs from the SSH login user: all remote operations run via `sudo`.

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `NTFY_TOPIC` | Optional. Send result notification via ntfy.sh |

Loaded from `.env` in the script directory if present.

---

## Security Notes

- Backup is created before any destructive write — recovery is always possible.
- `sudo cp` / `sudo tee` used instead of `sudo bash -c 'echo ... >'` to avoid shell injection.
- Key format is validated locally before any remote connection.
- `grep -vF` (fixed string) prevents regex injection from malformed key strings.
