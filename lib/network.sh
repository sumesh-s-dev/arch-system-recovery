#!/usr/bin/env bash
# lib/network.sh — network configuration for live USB environments
# Supports: NetworkManager (nmcli), systemd-networkd, wpa_supplicant, dhclient
set -euo pipefail

# ── setup_network ─────────────────────────────────────────────────────────────
# Auto-detects the best available network tool and establishes connectivity.
# For WiFi: asks for SSID and passphrase if not already connected.
setup_network() {
    log "Setting up network..."

    # Check if already connected
    if _network_already_up; then
        log "Network already available ($(ip route get 8.8.8.8 2>/dev/null \
            | awk '/src/{print $7}' | head -1 || echo 'connected'))"
        return 0
    fi

    # Show available interfaces
    log "Network interfaces:"
    ip link show 2>/dev/null | grep -E '^[0-9]+:' | \
        awk '{print "  " $2}' >> "${LOG_FILE}" || true

    # Try wired first, then WiFi
    if _try_wired; then
        log "Wired connection established."
        return 0
    fi

    log "No wired connection found — attempting WiFi..."
    if _try_wifi; then
        log "WiFi connection established."
        return 0
    fi

    warn "Could not establish network connection automatically."
    echo "  To connect manually, try:" >&2
    echo "    nmcli device wifi connect <SSID> password <pass>" >&2
    echo "    iwctl station wlan0 connect <SSID>" >&2
    echo "    dhclient eth0" >&2
}

# ── _network_already_up ───────────────────────────────────────────────────────
_network_already_up() {
    ping -c1 -W2 8.8.8.8 &>/dev/null || \
    ping -c1 -W2 archlinux.org &>/dev/null
}

# ── _try_wired ────────────────────────────────────────────────────────────────
_try_wired() {
    local eth_iface
    # Find first ethernet-like interface (not lo, not wlan/wl*)
    eth_iface="$(ip link show 2>/dev/null \
        | awk -F': ' '/^[0-9]+:/{print $2}' \
        | grep -vE '^(lo|wl|virbr|docker|veth)' \
        | head -1 || true)"

    [[ -z "${eth_iface}" ]] && return 1
    vlog "Trying wired on: ${eth_iface}"

    # Bring interface up
    ip link set "${eth_iface}" up >> "${LOG_FILE}" 2>&1 || true

    if command -v nmcli &>/dev/null; then
        nmcli device connect "${eth_iface}" >> "${LOG_FILE}" 2>&1 || true
    elif command -v dhclient &>/dev/null; then
        dhclient "${eth_iface}" >> "${LOG_FILE}" 2>&1 || true
    elif command -v dhcpcd &>/dev/null; then
        dhcpcd "${eth_iface}" >> "${LOG_FILE}" 2>&1 || true
    fi

    sleep 2
    _network_already_up
}

# ── _try_wifi ─────────────────────────────────────────────────────────────────
_try_wifi() {
    local wifi_iface
    wifi_iface="$(ip link show 2>/dev/null \
        | awk -F': ' '/^[0-9]+:/{print $2}' \
        | grep -E '^wl' | head -1 || true)"

    [[ -z "${wifi_iface}" ]] && { vlog "No WiFi interface found"; return 1; }
    vlog "WiFi interface: ${wifi_iface}"

    if command -v nmcli &>/dev/null; then
        _wifi_via_nmcli "${wifi_iface}"
    elif command -v iwctl &>/dev/null; then
        _wifi_via_iwctl "${wifi_iface}"
    elif command -v wpa_supplicant &>/dev/null; then
        _wifi_via_wpa "${wifi_iface}"
    else
        warn "No WiFi tool available (nmcli/iwctl/wpa_supplicant)"
        return 1
    fi
}

# ── nmcli ─────────────────────────────────────────────────────────────────────
_wifi_via_nmcli() {
    local iface="$1"
    log "Scanning for WiFi networks via nmcli..."

    # List networks
    nmcli device wifi list ifname "${iface}" 2>/dev/null >&2 || true

    local ssid passphrase
    echo "" >&2
    _c_yellow; printf "  WiFi SSID: "; _c_reset
    read -r ssid

    [[ -z "${ssid}" ]] && return 1

    _c_yellow; printf "  Password (leave blank if open): "; _c_reset
    read -rs passphrase; echo "" >&2

    if [[ -n "${passphrase}" ]]; then
        nmcli device wifi connect "${ssid}" password "${passphrase}" \
            ifname "${iface}" >> "${LOG_FILE}" 2>&1 || return 1
    else
        nmcli device wifi connect "${ssid}" ifname "${iface}" \
            >> "${LOG_FILE}" 2>&1 || return 1
    fi

    sleep 3
    _network_already_up
}

# ── iwctl (iwd) ───────────────────────────────────────────────────────────────
_wifi_via_iwctl() {
    local iface="$1"
    log "Connecting via iwctl..."

    local ssid
    echo "" >&2
    _c_yellow; printf "  WiFi SSID: "; _c_reset
    read -r ssid
    [[ -z "${ssid}" ]] && return 1

    iwctl --passphrase "" station "${iface}" connect "${ssid}" \
        >> "${LOG_FILE}" 2>&1 || {
        # Passphrase-protected network
        _c_yellow; printf "  Password: "; _c_reset
        local pass; read -rs pass; echo "" >&2
        iwctl --passphrase "${pass}" station "${iface}" connect "${ssid}" \
            >> "${LOG_FILE}" 2>&1 || return 1
    }

    sleep 3
    _network_already_up
}

# ── wpa_supplicant fallback ───────────────────────────────────────────────────
_wifi_via_wpa() {
    local iface="$1"
    log "Connecting via wpa_supplicant..."

    local ssid passphrase
    _c_yellow; printf "  WiFi SSID: "; _c_reset
    read -r ssid
    [[ -z "${ssid}" ]] && return 1

    _c_yellow; printf "  Password: "; _c_reset
    read -rs passphrase; echo "" >&2

    local conf
    conf="$(mktemp /tmp/wpa-XXXXXX.conf)" || return 1
    chmod 600 "${conf}" 2>/dev/null || true
    wpa_passphrase "${ssid}" "${passphrase}" > "${conf}" 2>/dev/null || {
        rm -f "${conf}"
        return 1
    }
    wpa_supplicant -B -i "${iface}" -c "${conf}" >> "${LOG_FILE}" 2>&1 || {
        rm -f "${conf}"; return 1
    }
    rm -f "${conf}"

    if command -v dhclient &>/dev/null; then
        dhclient "${iface}" >> "${LOG_FILE}" 2>&1 || true
    elif command -v dhcpcd &>/dev/null; then
        dhcpcd "${iface}" >> "${LOG_FILE}" 2>&1 || true
    fi

    sleep 3
    _network_already_up
}
