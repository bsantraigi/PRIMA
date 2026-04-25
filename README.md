# pim-activate

Automatically keep your Azure PIM (Privileged Identity Management) roles activated. Runs as a systemd user timer, checks every 30 minutes, and re-activates roles as they expire — no manual clicks in the Azure portal.

## How it works

1. **Reconciliation loop** — Every 30 minutes, compares your eligible PIM roles against currently active roles
2. **Activates missing roles** — Any eligible role not currently active gets activated with a configurable justification
3. **Expiry tracking** — Queries the Azure REST API for exact role expiration timestamps
4. **Precise re-activation** — Schedules a one-shot systemd timer to fire 2 minutes after roles expire, so downtime is minimal
5. **Cooldown** — Respects Azure's async provisioning (5-7 min) by not re-requesting activation within a 10-minute window

Never explicitly deactivates roles — lets them expire naturally to avoid Azure's unpredictable deactivation delays.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`) — logged in
- [azure-pim-cli](https://github.com/demoray/azure-pim-cli) (`az-pim`) — `cargo install azure-pim-cli`
- [jq](https://jqlang.github.io/jq/) — `sudo apt install jq`
- systemd with user session support (Linux)

## Install

```bash
git clone https://github.com/bishal-dce/pim-activate.git
cd pim-activate
./manage.sh install
```

This will:
- Generate a systemd service file with correct paths
- Enable a 30-minute heartbeat timer
- Enable linger (so the timer runs even without an active login session)

## Usage

```bash
./manage.sh status      # Show timer, last run, one-shot, cooldown state
./manage.sh run         # Run activation manually
./manage.sh logs        # Show recent journal logs
./manage.sh disable     # Pause the timer (roles expire naturally)
./manage.sh enable      # Resume the timer
./manage.sh uninstall   # Remove unit files, stop timers
```

## Configuration

Environment variables (set in your shell or modify the script):

| Variable | Default | Description |
|----------|---------|-------------|
| `PIM_JUSTIFICATION` | `Work` | Justification string for PIM activation |
| `PIM_DURATION` | `8 hours` | How long to activate roles for |

## Architecture

```
systemd timer (30 min heartbeat)
  │
  ├─ pim-activate.sh (reconcile)
  │   ├─ az-pim list          → eligible roles
  │   ├─ az-pim list --active → active roles
  │   ├─ diff → missing roles
  │   ├─ activate missing (with cooldown)
  │   └─ az rest → get earliest expiry
  │       └─ systemd-run one-shot at expiry + 2 min
  │
  └─ cooldown.json (per-role activation timestamps)
      └─ ~/.local/state/pim-activate/cooldown.json
```

## License

MIT
