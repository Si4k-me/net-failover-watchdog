#!/usr/bin/env bash
#
# net-failover-common.sh
# Shared hardware introspection, network state inspection, and security helpers
# for the net-failover-watchdog daemon and net-failover-watchdog-ctl utility.
#
# Author: Akshit Kamboj
# License: MIT
#

# ---------------------------------------------------------
# HARDWARE INTROSPECTION & CLASSIFICATION
# ---------------------------------------------------------

detect_interface_type() {
    local iface="$1"
    local syspath="/sys/class/net/${iface}"

    if [[ ! -d "$syspath" ]]; then
        echo "Other"
        return 0
    fi

    # 802.11 Wireless Architecture
    if [[ -d "${syspath}/wireless" || -d "${syspath}/phy80211" ]]; then
        echo "Wi-Fi"
        return 0
    fi

    # Hardware Bus Topology
    if [[ -d "${syspath}/device" ]]; then
        local devlink
        devlink=$(readlink -f "${syspath}/device" 2>/dev/null || echo "")

        # USB Bus (Cellular Dongles, LTE Modems, Phone Tethering)
        if [[ "$devlink" =~ /usb[0-9]+ ]]; then
            echo "USB/Cell"
            return 0
        fi

        # Check Kernel Driver Binding
        local driverlink
        driverlink=$(readlink -f "${syspath}/device/driver" 2>/dev/null || echo "")
        local driver="${driverlink##*/}"
        case "$driver" in
            cdc_ether|rndis_host|cdc_ncm|qmi_wwan|cdc_mbim|huawei_cdc_ncm|rndis_wlan)
                echo "USB/Cell"
                return 0
                ;;
        esac

        # Physical PCI / PCIe / Onboard Ethernet Controllers
        if [[ "$devlink" =~ /pci[0-9a-fA-F:]+ ]]; then
            echo "LAN (PCI)"
            return 0
        fi
    fi

    echo "Other"
}

classify_interface() {
    local iface="$1"
    [[ -z "$iface" ]] && { echo "${WEIGHT_OTHER:-4}"; return 0; }

    # User configured weight overrides
    if [[ -n "${INTERFACE_WEIGHTS[$iface]:-}" ]]; then
        echo "${INTERFACE_WEIGHTS[$iface]}"
        return 0
    fi

    local itype
    itype=$(detect_interface_type "$iface")
    case "$itype" in
        "LAN (PCI)") echo "${WEIGHT_LAN:-1}" ;;
        "USB/Cell")  echo "${WEIGHT_USB:-2}" ;;
        "Wi-Fi")     echo "${WEIGHT_WIFI:-3}" ;;
        *)           echo "${WEIGHT_OTHER:-4}" ;;
    esac
}

# ---------------------------------------------------------
# INTERFACE STATE & CARRIER DETECTION
# ---------------------------------------------------------

is_interface_carrier_up() {
    local iface="$1"
    [[ -z "$iface" ]] && return 1

    local syspath="/sys/class/net/${iface}"
    if [[ -d "$syspath" ]]; then
        local operstate="down"
        local carrier="0"

        [[ -f "${syspath}/operstate" ]] && operstate=$(cat "${syspath}/operstate" 2>/dev/null || echo "down")
        [[ -f "${syspath}/carrier" ]] && carrier=$(cat "${syspath}/carrier" 2>/dev/null || echo "0")

        # Some wireless/CDC drivers report operstate as 'unknown' when carrier is 1
        if [[ ("$operstate" == "up" || "$operstate" == "unknown") && "$carrier" == "1" ]]; then
            return 0
        fi
        return 1
    fi

    # Fallback when /sys/class/net is not available (e.g. network namespaces / containers)
    local link_info
    link_info=$(ip link show dev "$iface" 2>/dev/null || echo "")
    if [[ -n "$link_info" && ! "$link_info" =~ NO-CARRIER && ("$link_info" =~ state\ UP || "$link_info" =~ LOWER_UP) ]]; then
        return 0
    fi
    return 1
}

has_ipv4_address() {
    local iface="$1"
    [[ -z "$iface" ]] && return 1
    ip -4 addr show dev "$iface" 2>/dev/null | grep -q "inet "
}

get_interface_gateway() {
    local iface="$1"
    [[ -z "$iface" ]] && return 1

    local route_line
    route_line=$(ip -4 route show default dev "$iface" 2>/dev/null | head -n 1 || true)
    [[ -z "$route_line" ]] && return 1

    if [[ "$route_line" =~ via\ ([0-9a-fA-F.:]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    # Device-only route (point-to-point or link-scoped without via)
    if [[ "$route_line" =~ ^default ]]; then
        echo "dev"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------
# CONFIGURATION SECURITY VALIDATION
# ---------------------------------------------------------

verify_config_file_safety() {
    local file="$1"
    [[ ! -f "$file" ]] && return 0

    # 1. Enforce root ownership and strict permissions when running with root privileges
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        local file_uid
        file_uid=$(stat -c "%u" "$file" 2>/dev/null || echo "")
        if [[ -n "$file_uid" && "$file_uid" != "0" ]]; then
            echo "ERROR: Config file ${file} is not owned by root (UID ${file_uid}). Refusing to load for security." >&2
            return 1
        fi

        local file_mode
        file_mode=$(stat -c "%a" "$file" 2>/dev/null || echo "")
        # Reject group-writable or world-writable files (write bits: 2, 3, 6, 7)
        if [[ "$file_mode" =~ [2367]$ || "$file_mode" =~ [2367].$ ]]; then
            echo "ERROR: Config file ${file} has insecure write permissions (${file_mode}). Refusing to load." >&2
            return 1
        fi
    fi

    # 2. Block command substitution inside config files to prevent arbitrary execution
    if grep -qE '(`|\$\()' "$file" 2>/dev/null; then
        echo "ERROR: Config file ${file} contains disallowed command substitution (\` or \$()). Refusing to load." >&2
        return 1
    fi

    return 0
}
