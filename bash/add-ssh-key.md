# add-ssh-key.sh

Append a public SSH key to `authorized_keys` for a specified user on a remote host. Idempotent — skips silently if the key is already present.

---

## Prerequisites

- `ssh` client installed locally
- SSH host alias configured in `~/.ssh/config`, or a plain `user@host` string
- Passwordless SSH access to the remote host (key-based auth)
- If `--user` targets a different account than the SSH login user: `sudo` privileges on the remote host

---

## Usage

```bash
./add-ssh-key.sh --host <ssh-alias> --key <key-file-or-string> [--user <remote-user>] [--dry-run]
```

---

## Options

| Flag | Required | Description |
|------|----------|-------------|
| `--host` | Yes | SSH host alias from `~/.ssh/config`, or `user@host` |
| `--key` | Yes | Path to a `.pub` file, or the key string directly |
| `--user` | No | Target user on the remote host. Defaults to the SSH login user (no sudo). When set to a different user, `sudo` is used. |
| `--dry-run` | No | Print what would be done; make no changes |
| `-h`, `--help` | No | Show usage |

---

## Examples

```bash
# Add key to the SSH login user (alice) on myserver
./add-ssh-key.sh --host myserver --key ~/.ssh/id_ed25519.pub

# Add key to a different user (deploy) on myserver — requires sudo
./add-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub

# Pass the key as an inline string
./add-ssh-key.sh --host myserver --key "ssh-ed25519 AAAAC3Nz... user@laptop"

# Dry run — no changes made
./add-ssh-key.sh --host myserver --user deploy --key ~/.ssh/id_ed25519.pub --dry-run
```

---

## SSH Config Example

```
Host myserver
    HostName 10.0.1.42
    User ubuntu
    IdentityFile ~/.ssh/my-key.pem
```

With the above, `--host myserver` connects as `ubuntu`. Use `--user deploy` to add the key to the `deploy` account on that same host.

---

## Behavior

1. Resolves `--key` to a key string (reads file if path given; validates format).
2. SSHes to `--host`.
3. Creates `~/.ssh/` and `authorized_keys` on the remote if they don't exist (with correct `700`/`600` permissions).
4. Checks if the key is already present (`grep -qF`).
5. Appends the key only if not already present.
6. When `--user` differs from the SSH login user: all remote operations run via `sudo`.

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `NTFY_TOPIC` | Optional. Send result notification via ntfy.sh |

Loaded from `.env` in the script directory if present.

---

## Security Notes

- No credentials are hardcoded; the key is passed via the SSH session.
- `sudo tee -a` is used (not `sudo bash -c 'echo ... >>'`) to avoid shell injection.
- Key format is validated before any remote connection is attempted.
