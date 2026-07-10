# set-ssh-key.sh

Upsert a public SSH key in `authorized_keys` on a remote host. Matches existing entries by key blob — replaces the full line if options or comment differ, appends if absent. Handles keys with options prefixes (e.g. `no-agent-forwarding,permitopen="*:*" ssh-ed25519 ...`).

Use this instead of `add-ssh-key.sh` when the key has an options prefix, or when you want to update the options on an existing key.

---

## Prerequisites

- SSH access to the remote host (via alias in `~/.ssh/config` or `user@host`)
- If `--user` is specified: `sudo` access on the remote host

---

## Usage

```bash
./set-ssh-key.sh --host <ssh-alias> --key <key-file-or-string> [--user <remote-user>] [--dry-run]
```

---

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--host` | Yes | SSH host alias from `~/.ssh/config` (or `user@host`) |
| `--key`  | Yes | Path to a `.pub` file, or the full key string (with or without options prefix) |
| `--user` | No | Target user on the remote host. Defaults to SSH login user. When set, `sudo` is used. |
| `--dry-run` | No | Show what would be done; make no changes |
| `-h`, `--help` | No | Show help |

---

## Behavior

| State | Action |
|-------|--------|
| Key blob not present | Append full key line |
| Key blob present, exact line matches | No-op |
| Key blob present, options/comment differ | Backup + replace line |

Matching is done on the **key blob** (base64 field), so options and comments are ignored for lookup. The full line (including options) is what gets written.

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `NTFY_TOPIC` | Optional. Send result notification via ntfy.sh |

Loaded from `.env` in the script directory if present.

---

## Examples

```bash
# Set key with options (inline)
./set-ssh-key.sh --host myserver \
  --key 'no-agent-forwarding,no-X11-forwarding,permitopen="*:*" ssh-ed25519 AAAA... user@host'

# Set key from file for a different user (uses sudo)
./set-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub

# Dry run — shows what would change without modifying anything
./set-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub --dry-run
```

---

## Output

- Reports whether key was appended, replaced, or already up to date
- On replace: prints the old line and new line (in dry-run), creates a timestamped backup (e.g. `authorized_keys.bak.1717000000`)
- Prints elapsed time on exit
- Sends ntfy notification if `NTFY_TOPIC` is set

---

## Security Notes

- No credentials or key material are stored on disk locally
- Full key line is base64-encoded before passing over SSH to avoid shell quoting issues with options like `permitopen="*:*"`
- Backup created before any modification — never destructive
- `authorized_keys` permissions set to `600` after write
