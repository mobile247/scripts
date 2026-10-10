# freeze-pyenv-packages.zsh

Snapshot installed pip packages for every pyenv-managed Python version. Runs `pip freeze` against each version's interpreter and writes the output to a per-version text file under `~/.pyenv/`.

Useful before upgrading/uninstalling a Python version, or before migrating to a new machine, so packages can be reinstalled with `pip install -r`.

---

## Prerequisites

- `zsh` (uses zsh glob qualifiers and path modifiers — not bash-compatible)
- [pyenv](https://github.com/pyenv/pyenv) with versions installed under `~/.pyenv/versions/`
- `pip` available in each Python version (versions without pip are reported as failures)

---

## Usage

```bash
./freeze-pyenv-packages.zsh
```

No arguments.

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `NTFY_TOPIC` | Optional. Send result notification via ntfy.sh |

Loaded from `.env` in the current working directory if present, otherwise read from the environment. If `NTFY_TOPIC` is set in neither, the script runs normally and sends no notification.

---

## Behavior

| Condition | Action |
|-----------|--------|
| `~/.pyenv/versions/<version>/bin/python` exists and is executable | Run `python -m pip freeze`, write to `~/.pyenv/<version>-python-packages.txt` |
| `pip freeze` fails for a version | Error logged to stderr, previous snapshot for that version left untouched, continues to next version |
| Version directory has no executable `bin/python` | Skipped silently (not counted) |
| No version directories exist | No-op, success (`N` glob qualifier prevents a "no matches" error) |

Only directories are iterated (`/` glob qualifier); stray files in `~/.pyenv/versions/` are ignored. Virtualenvs created via `pyenv-virtualenv` also live under `~/.pyenv/versions/` and are frozen the same way.

Output is written to `<file>.tmp` first and moved into place only on success, so a failed freeze never replaces a good snapshot with an empty file.

---

## Output

One file per Python version, e.g.:

```
~/.pyenv/3.11.9-python-packages.txt
~/.pyenv/3.12.4-python-packages.txt
```

Each file is standard `pip freeze` format (`package==version` per line). A version with only `pip`/`setuptools` installed produces an empty file — `pip freeze` omits those.

On stdout: timestamped result line and elapsed time, e.g.

```
2026-10-10 12:00:04 success - 6 version(s) frozen
Time elapsed: 4s
```

Sends ntfy notification if `NTFY_TOPIC` is set.

**Side effects:** existing snapshot files are overwritten without prompting (on success only).

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All versions frozen (or none found) |
| `1` | One or more versions failed; failed versions listed in output and notification |

---

## Scheduling

Non-interactive, so it can run from cron or launchd. Neither sources `~/.zshrc`, and the working directory is not the script's folder (cron uses `$HOME`, launchd uses `/`). A scheduled run therefore sends no notification unless `NTFY_TOPIC` is provided by the scheduler or a `.env` exists in the working directory.

**cron** — daily at 12:00:

```bash
NTFY_TOPIC=your-topic
0 12 * * * /bin/zsh /path/to/freeze-pyenv-packages.zsh >> /tmp/pyenv-packages.log 2>&1
```

Or `cd` into a folder containing `.env` first: `0 12 * * * cd /path/with/env && /bin/zsh /path/to/freeze-pyenv-packages.zsh ...`

**launchd** — `~/Library/LaunchAgents/<label>.plist` with `ProgramArguments` set to `/bin/zsh` and the script path, `StartCalendarInterval` (`Hour` 12, `Minute` 0), and `StandardOutPath` / `StandardErrorPath` for logs. Provide `NTFY_TOPIC` via an `EnvironmentVariables` dict, or set `WorkingDirectory` to a folder containing `.env`. Check the last exit code with `launchctl list | grep <label>`.

---

## Restoring Packages

```bash
~/.pyenv/versions/3.12.4/bin/python -m pip install -r ~/.pyenv/3.12.4-python-packages.txt
```

---

## Examples

```bash
# Freeze all versions
./freeze-pyenv-packages.zsh

# Inspect results
ls ~/.pyenv/*-python-packages.txt
```
