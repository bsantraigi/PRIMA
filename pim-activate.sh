#!/usr/bin/env bash
set -euo pipefail

# pim-activate — Azure PIM Role Reconciliation Loop
# Activates eligible Azure PIM roles that aren't currently active.
# Schedules a precise one-shot timer for when roles expire.
# Designed to be called by a systemd timer every 30 minutes.
#
# https://github.com/bsantraigi/pim-activate

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/pim-activate"
COOLDOWN_FILE="$STATE_DIR/cooldown.json"
LOG_PREFIX="[pim-activate]"
COOLDOWN_SECONDS=600  # 10 minutes — don't re-request activation within this window
JUSTIFICATION="${PIM_JUSTIFICATION:-Work}"
ACTIVATION_DURATION="${PIM_DURATION:-8 hours}"
ACCOUNT_PREFIX="${PIM_ACCOUNT_PREFIX:-sc-}"
ONESHOT_BUFFER_SECONDS=300  # schedule one-shot 5 min after expected expiry
HEARTBEAT_SECONDS=1800      # 30 min — must match timer interval

log() { echo "$(date -Iseconds) $LOG_PREFIX $*"; }
log_err() { echo "$(date -Iseconds) $LOG_PREFIX ERROR: $*" >&2; }

# Ensure state directory and cooldown file exist
mkdir -p "$STATE_DIR"
[[ -f "$COOLDOWN_FILE" ]] || echo '{}' > "$COOLDOWN_FILE"

# --- Prerequisites check ---
for cmd in az az-pim jq; do
    if ! command -v "$cmd" &>/dev/null; then
        log_err "$cmd not found in PATH. Install it first."
        exit 1
    fi
done

# Verify az login
if ! az account show &>/dev/null; then
    log_err "az CLI not logged in. Run: az login"
    exit 1
fi

# Verify account prefix if configured
az_user=$(az account show --query user.name -o tsv 2>/dev/null)
if [[ -n "$ACCOUNT_PREFIX" && "$az_user" != "${ACCOUNT_PREFIX}"* ]]; then
    log_err "Logged in as '$az_user' — expected prefix '$ACCOUNT_PREFIX'. Aborting."
    exit 1
fi
log "Authenticated as $az_user"

# --- Fetch eligible and active roles ---
log "Fetching eligible roles..."
eligible=$(az-pim list --quiet 2>/dev/null) || { log_err "Failed to list eligible roles"; exit 1; }

log "Fetching active roles..."
active=$(az-pim list --active --quiet 2>/dev/null) || { log_err "Failed to list active roles"; exit 1; }

# --- Compute missing roles (eligible - active) ---
# Key each role by "role|scope" and find those in eligible but not in active
missing=$(jq -n \
    --argjson eligible "$eligible" \
    --argjson active "$active" \
    '[$active | .[] | .role + "|" + .scope] as $a_keys |
     [$eligible | .[] | select((.role + "|" + .scope) as $k | $a_keys | index($k) | not)]'
)

missing_count=$(echo "$missing" | jq 'length')
log "Eligible: $(echo "$eligible" | jq 'length'), Active: $(echo "$active" | jq 'length'), Missing: $missing_count"

# --- Activate missing roles, respecting cooldown ---
now=$(date +%s)
cooldown=$(cat "$COOLDOWN_FILE")
activated_any=false

if [[ "$missing_count" -gt 0 ]]; then
    # Build list of roles to activate (not in cooldown)
    to_activate="[]"

    for i in $(seq 0 $((missing_count - 1))); do
        role=$(echo "$missing" | jq -r ".[$i].role")
        scope=$(echo "$missing" | jq -r ".[$i].scope")
        key="${role}|${scope}"
        last_requested=$(echo "$cooldown" | jq -r --arg k "$key" '.[$k] // 0')

        age=$((now - last_requested))
        if [[ "$age" -lt "$COOLDOWN_SECONDS" ]]; then
            log "Skipping '$role' @ $(echo "$missing" | jq -r ".[$i].scope_name") (pending, requested ${age}s ago)"
            continue
        fi

        to_activate=$(echo "$to_activate" | jq --argjson role "$(echo "$missing" | jq ".[$i]")" '. + [$role]')
        cooldown=$(echo "$cooldown" | jq --arg k "$key" --argjson t "$now" '. + {($k): $t}')
    done

    to_activate_count=$(echo "$to_activate" | jq 'length')

    if [[ "$to_activate_count" -gt 0 ]]; then
        log "Activating $to_activate_count role(s) with duration '$ACTIVATION_DURATION'..."
        if echo "$to_activate" | az-pim activate set --config /dev/stdin --duration "$ACTIVATION_DURATION" "$JUSTIFICATION" 2>&1; then
            log "Activation request sent successfully"
            activated_any=true
        else
            log_err "Activation request failed (some roles may have succeeded)"
            activated_any=true  # still write cooldown to avoid immediate retry
        fi
    fi

    # Write updated cooldown
    echo "$cooldown" > "$COOLDOWN_FILE"
fi

# --- If we just activated, stop here. Next tick will check expiry. ---
if [[ "$activated_any" == "true" ]]; then
    log "Activation requested. Will check expiry on next heartbeat."
    exit 0
fi

# --- All eligible roles are active. Check expiry and schedule one-shot. ---
if [[ "$missing_count" -eq 0 ]]; then
    log "All eligible roles are active. Checking expiry..."
    earliest_expiry=$(az rest --method GET \
        --url "https://management.azure.com/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=2020-10-01&\$filter=asTarget()" \
        --query "value[?properties.assignmentType=='Activated'].properties.endDateTime | sort(@) | [0]" \
        -o tsv 2>/dev/null) || true

    if [[ -z "$earliest_expiry" || "$earliest_expiry" == "None" ]]; then
        log "No PIM-activated roles with expiry found (all permanent)."
        exit 0
    fi

    expiry_epoch=$(date -d "$earliest_expiry" +%s 2>/dev/null) || {
        log_err "Failed to parse expiry timestamp: $earliest_expiry"
        exit 0
    }
    seconds_until=$((expiry_epoch - now))
    log "Earliest expiry: $earliest_expiry (in ${seconds_until}s)"

    # Schedule one-shot if expiry is within the next heartbeat + buffer
    if [[ "$seconds_until" -lt "$((HEARTBEAT_SECONDS + 300))" ]]; then
        oneshot_delay=$((seconds_until + ONESHOT_BUFFER_SECONDS))
        if [[ "$oneshot_delay" -lt 60 ]]; then
            oneshot_delay=60
        fi

        # Cancel any existing one-shot before scheduling
        systemctl --user stop pim-activate-oneshot.timer 2>/dev/null || true

        log "Scheduling one-shot in ${oneshot_delay}s (expiry + ${ONESHOT_BUFFER_SECONDS}s buffer)..."
        systemd-run --user --on-active="${oneshot_delay}s" \
            --unit=pim-activate-oneshot \
            --description="PIM role re-activation after expiry" \
            "$SCRIPT_DIR/pim-activate.sh" 2>&1 || {
            log_err "Failed to schedule one-shot timer"
        }
    else
        log "Expiry is far away (${seconds_until}s). Heartbeat will handle it."
    fi
fi

log "Done."
