# Story: How pim-activate came to be

## The pain

Azure PIM (Privileged Identity Management) requires you to manually activate roles before you can use them. The roles expire after 8 hours. If you have 14 eligible roles across multiple subscriptions, clusters, and storage accounts, that's 14 roles to re-activate multiple times per day through the Azure portal. Forget once, and your GPU cluster job submission fails, your storage access is denied, or your OpenAI API calls start returning 403s.

## The first attempt: cron + bash

The original setup was three files scattered in `$HOME`, outside any version control:

- **`~/cron-env`** — A manually captured snapshot of environment variables, because cron jobs run with a minimal `PATH` that can't find `az-pim`. Created by running `env > ~/cron-env` inside a cron session.
- **`~/run-as-cron`** — A 2-line shell wrapper that sources `cron-env` and executes a command under `env -i`, simulating the cron environment for interactive testing.
- **`~/pim-cron.sh`** — The actual activation script: check `az` login, deactivate all roles, reactivate all roles, log to a file.

The crontab entry was `1 */4 * * *` (every 4 hours at minute 1), but it was **commented out** — it had stopped working at some point and was never debugged.

### Problems with this approach

1. **Not version controlled** — Scripts lived in `$HOME` with no backup and no history.
2. **Hardcoded paths** — `/home/bishal/` everywhere, not portable.
3. **Deactivate-then-activate race condition** — Azure PIM deactivation is asynchronous and takes 5–7 minutes. The script would deactivate all roles, then immediately try to activate them. During that 5–7 minute window, roles are in limbo — not yet deactivated, can't be reactivated. This was the likely cause of the commented-out crontab.
4. **`$USER` unset in cron** — The log file path used `${USER}` which is empty in cron's minimal environment, so logs went to `_pim_log.log`.
5. **Wrong stderr redirect** — `2>&1 >> file` doesn't capture stderr to the file (should be `>> file 2>&1`).
6. **`cron-env` is fragile** — Manually maintained, environment-specific, breaks on any system change.
7. **No self-healing** — If a single role fails to activate, there's no retry logic; the whole batch either works or fails silently.

## Design evolution

### Iteration 1: Move to systemd, fix the obvious bugs

Replace cron with a systemd user timer. Advantages: proper environment inheritance (no `cron-env` needed), journal logging (no manual log files), `loginctl enable-linger` for running without login.

Fixed the deactivation race by removing explicit deactivation entirely — let roles expire naturally after 8 hours.

### Iteration 2: How often to run?

The naive answer to "every 8h15m" was three fixed cron times per day. But cron can't express arbitrary intervals cleanly. Systemd timers can (`OnUnitActiveSec=8h15min`), but a single 8h15m interval means up to 8h15m of downtime if a role gets manually deactivated mid-cycle.

Decision: **30-minute heartbeat**. The diff logic (eligible minus active) is cheap when everything is active — just two `az-pim list` calls, no activation API calls. Cost: ~15 seconds and 2 HTTP requests every 30 minutes.

### Iteration 3: Can we know when roles expire?

Initially assumed `az-pim` doesn't expose expiration timestamps (it doesn't in its normal JSON output). But increasing verbosity (`--verbose --verbose`) revealed the raw Azure API response body in TRACE logs, containing `startDateTime` and `endDateTime` fields.

Parsing TRACE logs is fragile (depends on internal log format of a specific `az-pim` version). Instead, discovered that `az rest` can call the same Azure Management API directly:

```bash
az rest --method GET \
  --url "https://management.azure.com/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=2020-10-01&\$filter=asTarget()" \
  --query "value[?properties.assignmentType=='Activated'].properties.endDateTime | sort(@) | [0]" \
  -o tsv
```

Returns the exact expiration timestamp. Stable, documented API, uses existing `az` credentials.

### Iteration 4: Precise wake-up at expiry

With exact expiry known, the script schedules a one-shot systemd timer (`systemd-run --user --on-active=Xs`) to fire 5 minutes after the earliest role expires. This reduces worst-case re-activation latency from 30 minutes (heartbeat) to ~5 minutes.

The one-shot is belt-and-suspenders: if it fails (reboot, systemd hiccup), the 30-minute heartbeat catches it as fallback.

### Iteration 5: Respecting Azure's async provisioning

Azure PIM activation is asynchronous. When `az-pim activate set` returns success, the role might not appear in `az-pim list --active` for another 5–7 minutes. Without tracking this, the next heartbeat would see the role as "missing" and try to activate it again (wasted call, possible error).

Solution: **per-role cooldown file**. After requesting activation, the script records the role and timestamp in `~/.local/state/pim-activate/cooldown.json`. For the next 10 minutes, that role is skipped. The cooldown is soft state — deleting the file is harmless; the system self-corrects (worst case: one redundant activation attempt).

Why per-role and not a single batch timestamp:
- A new role added to your eligible set shouldn't be blocked by an unrelated role's cooldown
- If 1 of 14 roles fails, only that role retries after cooldown — the rest aren't affected
- Roles manually deactivated can be re-activated independently

### Iteration 6: The reconciliation pattern

The final design follows the **Kubernetes controller reconciliation pattern**:

```
observe → diff → act → schedule next
```

Azure is always the source of truth. Local state (cooldown file) is only a performance optimization to avoid redundant API calls during the provisioning window.

Properties of the system:
- **Self-healing** — Any state mismatch caught within 30 minutes
- **Idempotent** — Running twice is harmless
- **Crash-safe** — If the script dies mid-run, the next tick resumes cleanly
- **Zero-config** — No config file listing roles; discovers eligible roles from Azure automatically
- **No explicit deactivation** — Eliminates the async race condition entirely

## What we never do

- **Never explicitly deactivate** — Roles expire naturally. Deactivation is async (5–7 min) and creates a race condition gap.
- **Never re-request during cooldown** — Respects Azure's provisioning delay.
- **Never parse TRACE logs** — Uses the stable `az rest` API for expiration timestamps.
- **Never hardcode paths** — Service file is generated at install time with the correct absolute paths.
- **Never maintain a role list** — Eligible roles are discovered dynamically from Azure.

## Files that became obsolete

| Old file | What it was | Replaced by |
|----------|-------------|-------------|
| `~/cron-env` | Manually captured environment snapshot | Systemd `Environment=` directive |
| `~/run-as-cron` | Wrapper to simulate cron environment | Not needed with systemd |
| `~/pim-cron.sh` | Deactivate-then-activate script | `pim-activate.sh` (reconciliation loop) |
| `az_pim_roles.json` | Static role list (was unused) | Dynamic discovery via `az-pim list` |
| Crontab entry | `1 */4 * * *` (commented out) | Systemd timer (30-min heartbeat) |
