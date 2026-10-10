# scripts

Personal collection of scripts for things I want to automate — mostly AWS infrastructure and DevOps tasks, but not limited to them.

## Structure

```
scripts/
├── bash/       # Bash scripts; each paired with a .md doc
├── python/     # Python scripts; each paired with a .md doc
└── zsh/        # Zsh scripts; each paired with a .md doc
```

Each script has a matching `.md` file with the same base name covering prerequisites, environment variables, usage, and output.

## Scripts

| Script | Language | Purpose |
|--------|----------|---------|
| `share-rds-snapshot.sh` | Bash | Create RDS snapshot, share with target AWS account, copy to target |
| `change-ec2-instance-type.sh` | Bash | Stop EC2 instance, change type, restart |
| `restart-instance.sh` | Bash | Stop/start EC2 instance by Name tag (interactive multi-match) |
| `start-instance.sh` | Bash | Start EC2 instance with exponential backoff retry on InsufficientCapacity |
| `deactivate-iam-user.sh` | Bash | Disable all credentials for an IAM user (keys, MFA, password, certs) |
| `copy-target-group.sh` | Bash | Clone ALB target group with all config, attributes, tags, and targets |
| `env-to-ecs-yaml.sh` | Bash | Convert `.env` file to ECS YAML or Docker CLI `-e` format |
| `add-ssh-key.sh` | Bash | Append a public SSH key to a remote user's `authorized_keys` (idempotent) |
| `remove-ssh-key.sh` | Bash | Remove a public SSH key from a remote user's `authorized_keys` (idempotent, auto-backup) |
| `set-ssh-key.sh` | Bash | Upsert an SSH key by key blob — replaces the line if options/comment differ, appends if absent |
| `rotate-ssh-key.sh` | Bash | Replace an old SSH key with a new one across one or more hosts |
| `clear-docker.sh` | Bash | Remove all Docker containers, images, volumes, networks, cache |
| `epub-splitter.py` | Python | Split a huge EPUB into smaller multi-volume EPUBs by parts/chapters/size |
| `freeze-pyenv-packages.zsh` | Zsh | `pip freeze` every pyenv Python version into `~/.pyenv/<version>-python-packages.txt` |

## Requirements

- AWS scripts: `aws` CLI configured with named profiles
- `change-ec2-instance-type.sh`: also requires `jq`
- `epub-splitter.py`: Python 3 + `pip install -r python/epub-splitter.requirements.txt`
- `freeze-pyenv-packages.zsh`: `zsh` and pyenv
- Notifications (optional): `curl` or `wget` + `NTFY_TOPIC`

## Configuration

Scripts read `.env` from the current working directory if present, otherwise use variables already set in the environment. Optional settings like `NTFY_TOPIC` can be left out entirely — the script just skips that feature.

## Usage

Most scripts support `--dry-run`. Always run that first.

```bash
cd bash/
./share-rds-snapshot.sh --dry-run
./change-ec2-instance-type.sh --instance-id i-xxx --instance-type t3.medium --dry-run
```

See the matching `.md` file for each script's full usage and environment variable reference.

## License

MIT — see [LICENSE](LICENSE).
