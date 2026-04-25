#!/usr/bin/env bash
set -euo pipefail

# pim-activate — Service Manager
# Usage: ./manage.sh {install|uninstall|enable|disable|status|run|logs}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="pim-activate"
UNIT_DIR="${HOME}/.config/systemd/user"

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

check_prerequisites() {
    local missing=()
    for cmd in az az-pim jq systemctl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        red "Missing prerequisites: ${missing[*]}"
        echo "Install them first:"
        echo "  az      → https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
        echo "  az-pim  → cargo install azure-pim-cli"
        echo "  jq      → sudo apt install jq"
        exit 1
    fi

    if ! az account show &>/dev/null; then
        red "Azure CLI not logged in. Run: az login"
        exit 1
    fi
}

generate_service_file() {
    local script_path="$SCRIPT_DIR/pim-activate.sh"
    cat > "$UNIT_DIR/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Activate Azure PIM eligible roles
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${script_path}
Environment=PATH=${HOME}/.cargo/bin:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
EOF
}

do_install() {
    check_prerequisites

    bold "Installing pim-activate..."

    mkdir -p "$UNIT_DIR"
    chmod +x "$SCRIPT_DIR/pim-activate.sh"

    # Generate service file with correct paths for this machine
    generate_service_file

    # Timer is static — symlink it
    ln -sf "$SCRIPT_DIR/${SERVICE_NAME}.timer" "$UNIT_DIR/${SERVICE_NAME}.timer"

    systemctl --user daemon-reload
    systemctl --user enable --now "${SERVICE_NAME}.timer"

    # Enable linger so timers run without active login session
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
        echo "Enabling linger for user $USER (timers run without login)..."
        loginctl enable-linger "$USER" 2>/dev/null || {
            echo "Warning: Could not enable linger. Timer only runs when logged in."
            echo "Run manually: sudo loginctl enable-linger $USER"
        }
    fi

    green "Installed. Timer active."
    do_status
}

do_uninstall() {
    bold "Uninstalling pim-activate..."

    systemctl --user stop "${SERVICE_NAME}.timer" 2>/dev/null || true
    systemctl --user disable "${SERVICE_NAME}.timer" 2>/dev/null || true
    systemctl --user stop pim-activate-oneshot.timer 2>/dev/null || true

    rm -f "$UNIT_DIR/${SERVICE_NAME}.service" "$UNIT_DIR/${SERVICE_NAME}.timer"
    systemctl --user daemon-reload

    green "Uninstalled. Unit files removed."
    echo "State directory preserved at: ${XDG_STATE_HOME:-$HOME/.local/state}/pim-activate/"
}

do_enable() {
    systemctl --user enable --now "${SERVICE_NAME}.timer"
    green "Timer enabled."
    do_status
}

do_disable() {
    systemctl --user stop "${SERVICE_NAME}.timer"
    systemctl --user stop pim-activate-oneshot.timer 2>/dev/null || true
    green "Timer disabled. Roles will expire naturally."
}

do_status() {
    bold "=== Timer ==="
    systemctl --user status "${SERVICE_NAME}.timer" --no-pager 2>/dev/null || echo "Timer not installed."
    echo ""
    bold "=== Last Run ==="
    systemctl --user status "${SERVICE_NAME}.service" --no-pager 2>/dev/null || echo "Service not installed."
    echo ""
    bold "=== One-shot ==="
    systemctl --user status pim-activate-oneshot.timer --no-pager 2>/dev/null || echo "No one-shot scheduled."
    echo ""
    bold "=== Cooldown State ==="
    local cooldown_file="${XDG_STATE_HOME:-$HOME/.local/state}/pim-activate/cooldown.json"
    if [[ -f "$cooldown_file" ]]; then
        jq . "$cooldown_file"
    else
        echo "No cooldown state."
    fi
}

do_run() {
    bold "Running PIM activation manually..."
    "$SCRIPT_DIR/pim-activate.sh"
}

do_logs() {
    journalctl --user -u "${SERVICE_NAME}.service" --no-pager -n 50
}

case "${1:-}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    enable)    do_enable ;;
    disable)   do_disable ;;
    status)    do_status ;;
    run)       do_run ;;
    logs)      do_logs ;;
    *)
        echo "Usage: $0 {install|uninstall|enable|disable|status|run|logs}"
        echo ""
        echo "  install    — Check prerequisites, generate service, enable timer"
        echo "  uninstall  — Disable timer, remove unit files"
        echo "  enable     — Start the heartbeat timer"
        echo "  disable    — Stop all timers (roles expire naturally)"
        echo "  status     — Show timer, service, one-shot, and cooldown state"
        echo "  run        — Run activation manually (one-shot)"
        echo "  logs       — Show recent journal logs"
        exit 1
        ;;
esac
