# pim-activate

Automatically keep your Azure PIM (Privileged Identity Management) roles activated. Runs as a systemd user timer, checks every 30 minutes, and re-activates roles as they expire — no manual clicks in the Azure portal.

## The problem

Azure PIM roles expire after a fixed duration (typically 8 hours). If you have 10+ eligible roles across multiple subscriptions, manually re-activating them through the portal several times a day is painful. Forgetting to re-activate breaks your workflows — failed deployments, denied storage access, cluster jobs that can't submit.

## How it works

Uses a **reconciliation loop** pattern (inspired by Kubernetes controllers): observe the actual state, diff against desired state, act to converge, repeat.

1. **Observe** — Fetches eligible roles (`az-pim list`) and active roles (`az-pim list --active`)
2. **Diff** — Computes which eligible roles are missing from the active set
3. **Act** — Activates missing roles, respecting a per-role cooldown to avoid hammering Azure during its async provisioning window (5–7 min)
4. **Schedule** — Queries the Azure REST API for exact role expiration timestamps and schedules a one-shot timer to fire 5 minutes after the earliest expiry

Key design choice: **never explicitly deactivates roles**. Azure PIM deactivation is asynchronous and takes 5–7 minutes of unpredictable delay. Attempting deactivate-then-activate creates a race condition with a gap where roles are neither active nor fully deactivated. Instead, roles are allowed to expire naturally, then re-activated cleanly.

## Prerequisites

| Tool | Install | Purpose |
|------|---------|---------|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`) | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` | Azure authentication and REST API calls |
| [azure-pim-cli](https://github.com/demoray/azure-pim-cli) (`az-pim`) | `cargo install azure-pim-cli` | PIM role listing and activation |
| [jq](https://jqlang.github.io/jq/) | `sudo apt install jq` | JSON processing |
| systemd | (included in most Linux distros) | Timer scheduling |

You must be logged into Azure CLI before installing: `az login`.

## Install

```bash
git clone https://github.com/bsantraigi/pim-activate.git
cd pim-activate
./manage.sh install
```

This will:
- Check all prerequisites are installed and `az` is logged in
- Generate a systemd user service file with correct absolute paths for your machine
- Symlink the timer unit to `~/.config/systemd/user/`
- Enable and start the 30-minute heartbeat timer
- Enable linger (`loginctl enable-linger`) so the timer runs even without an active login session

The service file is **generated, not checked in** — it contains absolute paths specific to where you cloned the repo. If you move the repo, run `./manage.sh install` again.

## Usage

```bash
./manage.sh install     # First-time setup (or after moving the repo)
./manage.sh status      # Show timer, last run, one-shot, and cooldown state
./manage.sh run         # Run activation manually right now
./manage.sh logs        # Show recent journal logs (last 50 entries)
./manage.sh disable     # Pause the timer (roles will expire naturally)
./manage.sh enable      # Resume the timer
./manage.sh uninstall   # Stop timers, remove unit files
```

### Checking logs

```bash
# Via manage.sh
./manage.sh logs

# Or directly via journalctl
journalctl --user -u pim-activate.service -f          # follow live
journalctl --user -u pim-activate.service --since today
```

### Manual one-off activation

```bash
./manage.sh run
```

This runs the full reconciliation loop once — useful for immediate activation after a fresh `az login` or to test changes.

## Configuration

Environment variables (set in your shell or export before running):

| Variable | Default | Description |
|----------|---------|-------------|
| `PIM_JUSTIFICATION` | `Work` | Justification string sent with each activation request |
| `PIM_DURATION` | `8 hours` | How long to activate roles for (Azure PIM max is typically 8h) |
| `PIM_ACCOUNT_PREFIX` | `sc-` | Only allow accounts whose UPN starts with this prefix. Set to empty string to disable |

To make these permanent for the systemd service, add them to the generated service file's `Environment=` line after installing.

## Architecture

```
                    ┌─────────────────────────────┐
                    │   systemd timer (30 min)    │
                    │   + one-shot at expiry+5min │
                    └──────────┬──────────────────┘
                               │ triggers
                               ▼
                    ┌─────────────────────────────┐
                    │   pim-activate.sh           │
                    │   (reconciliation loop)     │
                    └──────────┬──────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
     ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐
     │ az-pim list  │ │ az-pim list  │ │ az rest          │
     │ (eligible)   │ │ --active     │ │ (expiry times)   │
     └──────────────┘ └──────────────┘ └──────────────────┘
              │                │                │
              ▼                ▼                ▼
     ┌─────────────────────────────────────────────────────┐
     │                    Reconcile                        │
     │  missing = eligible - active                        │
     │  for each missing role:                             │
     │    if not in cooldown → activate                    │
     │  if all active → check expiry → schedule one-shot   │
     └─────────────────────────────────────────────────────┘
              │
              ▼
     ┌──────────────────┐
     │  cooldown.json   │  (per-role timestamps)
     │  ~/.local/state/ │
     │  pim-activate/   │
     └──────────────────┘
```

### Files

| File | Description |
|------|-------------|
| `pim-activate.sh` | Main reconciliation script (~130 lines of bash) |
| `pim-activate.timer` | Systemd timer unit (static — no machine-specific paths) |
| `manage.sh` | Install/uninstall/lifecycle management |
| `~/.config/systemd/user/pim-activate.service` | Generated at install time with correct paths |
| `~/.local/state/pim-activate/cooldown.json` | Per-role cooldown timestamps (safe to delete) |

### API call budget per heartbeat

| Scenario | API calls | Time |
|----------|-----------|------|
| All roles active, expiry far away | 3 (`list` × 2 + `az rest`) | ~15s |
| All roles active, expiry soon | 3 + one-shot scheduled | ~15s |
| Some roles missing, activation needed | 3 (`list` × 2 + `activate`) | ~15s |
| Recently activated (cooldown) | 2 (`list` × 2, skips activate) | ~10s |

### Per-role cooldown

The cooldown file tracks when each role was last requested for activation. This prevents re-requesting activation during Azure's 5–7 minute async provisioning window. The key is `"RoleName|/full/scope/path"` and the value is a Unix epoch timestamp. Entries older than 10 minutes are ignored (not pruned — they're harmless). Deleting the file entirely is safe; the system self-corrects on the next tick.

### One-shot timer

When all eligible roles are active and the earliest expiry is within 35 minutes (the next heartbeat might miss it), the script schedules a transient systemd timer via `systemd-run --user --on-active=Xs`. This fires at expiry + 5 minutes, runs the same reconciliation script, and catches the expired roles immediately. If the one-shot misses (reboot, systemd issue), the 30-minute heartbeat catches it as a fallback.

## Troubleshooting

**`az-pim not found in PATH`** — The systemd service sets its own `PATH`. If `az-pim` is installed somewhere unusual, update the `Environment=PATH=...` line in `~/.config/systemd/user/pim-activate.service`.

**`az CLI not logged in`** — Run `az login` in your terminal. The systemd service uses the same credential cache (typically `~/.azure/`).

**Timer not running after reboot** — Check `loginctl show-user $USER | grep Linger`. If `Linger=no`, run `sudo loginctl enable-linger $USER`.

**Roles not activating** — Check `./manage.sh logs` for errors. Common causes: expired `az` token, `az-pim` version mismatch, Azure throttling.

**Want to change the heartbeat interval?** — Edit `OnUnitActiveSec=30min` in `pim-activate.timer`, then `./manage.sh install` to reload.

## License

MIT — see [LICENSE](LICENSE).
