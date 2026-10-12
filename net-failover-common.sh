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

has_ipv6_global_address() {
    local iface="$1"
    [[ -z "$iface" ]] && return 1
    ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q "inet6 "
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

get_interface_ipv6_gateway() {
    local iface="$1"
    [[ -z "$iface" ]] && return 1

    local route_line
    route_line=$(ip -6 route show default dev "$iface" 2>/dev/null | head -n 1 || true)
    [[ -z "$route_line" ]] && return 1

    if [[ "$route_line" =~ via\ ([0-9a-fA-F:]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    if [[ "$route_line" =~ ^default ]]; then
        echo "dev"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------
# INTERFACE DISCOVERY & FILTERING
# ---------------------------------------------------------

DEFAULT_IGNORED_INTERFACES=("lo" "docker*" "veth*" "virbr*" "tun*" "tap*" "wg*" "br-*" "podman*" "vmnet*" "vboxnet*")

is_ignored_interface() {
    local iface="$1"
    [[ -z "$iface" ]] && return 0

    local patterns=("${DEFAULT_IGNORED_INTERFACES[@]}")
    if [[ -n "${IGNORED_INTERFACES[*]:-}" ]]; then
        patterns=("${IGNORED_INTERFACES[@]}")
    fi

    for pattern in "${patterns[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$iface" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

discover_interfaces() {
    local candidates=()
    local managed="${MANAGED_INTERFACES:-auto}"

    if [[ "$managed" != "auto" && ${#MANAGED_INTERFACES[@]} -gt 0 ]]; then
        for iface in "${MANAGED_INTERFACES[@]}"; do
            [[ -z "$iface" ]] && continue
            if [[ -d "/sys/class/net/${iface}" ]] || ip link show dev "$iface" >/dev/null 2>&1; then
                candidates+=("$iface")
            fi
        done
    else
        # Auto-discovery via sysfs
        local sys_ifaces=()
        if [[ -d /sys/class/net ]]; then
            for devpath in /sys/class/net/*; do
                [[ ! -e "$devpath" ]] && continue
                local devname="${devpath##*/}"
                [[ -z "$devname" ]] && continue
                is_ignored_interface "$devname" && continue

                if ip -4 route show default dev "$devname" 2>/dev/null | grep -q "^default"; then
                    sys_ifaces+=("$devname")
                elif is_interface_carrier_up "$devname" && { has_ipv4_address "$devname" || has_ipv6_global_address "$devname"; }; then
                    sys_ifaces+=("$devname")
                fi
            done
        fi

        # Also inspect ip link for namespaces/containers
        while IFS= read -r line; do
            local ifname
            ifname=$(echo "$line" | awk -F': ' '{print $2}' | awk -F'@' '{print $1}')
            [[ -z "$ifname" ]] && continue
            is_ignored_interface "$ifname" && continue
            if ip -4 route show default dev "$ifname" 2>/dev/null | grep -q "^default"; then
                sys_ifaces+=("$ifname")
            elif is_interface_carrier_up "$ifname" && { has_ipv4_address "$ifname" || has_ipv6_global_address "$ifname"; }; then
                sys_ifaces+=("$ifname")
            fi
        done < <(ip -o link show 2>/dev/null || true)

        # Deduplicate
        if [[ ${#sys_ifaces[@]} -gt 0 ]]; then
            IFS=$'\n' read -d '' -r -a candidates < <(printf '%s\n' "${sys_ifaces[@]}" | sort -u && printf '\0') || true
        fi
    fi

    if [[ ${#candidates[@]} -gt 0 ]]; then
        printf '%s\n' "${candidates[@]}"
    fi
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

# ---------------------------------------------------------
# DECLARATIVE CONFIGURATION PARSER
# ---------------------------------------------------------
# Safely parses key=value, arrays, and associative array overrides
# without executing 'source' or 'eval' on configuration files.
parse_declarative_config() {
    local file="$1"
    [[ ! -f "$file" ]] && return 0

    local pat_override='^INTERFACE_WEIGHTS\[[\"'\'']?([a-zA-Z0-9_.-]+)[\"'\'']?\][[:space:]]*=[[:space:]]*([0-9]+)$'
    local pat_map_item='\[[\"'\'']?([a-zA-Z0-9_.-]+)[\"'\'']?\][[:space:]]*=[[:space:]]*([0-9]+)'
    local pat_array_single='^([A-Z0-9_]+)[[:space:]]*=[[:space:]]*\((.*)\)$'
    local pat_array_start='^([A-Z0-9_]+)[[:space:]]*=[[:space:]]*\((.*)$'
    local pat_scalar='^([A-Z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$'
    local pat_unsafe='[;&|\`\$]'

    local in_array=""
    local array_buffer=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Associative array compound assignment: INTERFACE_WEIGHTS=( ["veth0"]=1 ["veth1"]=2 )
        if [[ "$line" =~ INTERFACE_WEIGHTS[[:space:]]*=[[:space:]]*\((.*)\) ]]; then
            local map_content="${BASH_REMATCH[1]}"
            while [[ "$map_content" =~ $pat_map_item ]]; do
                local mk="${BASH_REMATCH[1]}"
                local mv="${BASH_REMATCH[2]}"
                INTERFACE_WEIGHTS["$mk"]="$mv"
                map_content="${map_content#*${mk}}"
                map_content="${map_content#*${mv}}"
            done
            continue
        fi

        # Ignore standalone declare statements (e.g. declare -A INTERFACE_WEIGHTS)
        [[ "$line" =~ ^declare[[:space:]]+-[a-zA-Z]+ ]] && continue

        if [[ -n "$in_array" ]]; then
            if [[ "$line" =~ (.*)\)[[:space:]]*(#.*)?$ ]]; then
                local closing_content="${BASH_REMATCH[1]}"
                closing_content="${closing_content%%#*}"
                array_buffer+=" ${closing_content}"
                local items=()
                local raw_items
                IFS=$' \t\n' read -r -a raw_items <<< "$array_buffer"
                for token in "${raw_items[@]}"; do
                    token="${token%,}"
                    token="${token%\"}"
                    token="${token#\"}"
                    token="${token%\'}"
                    token="${token#\'}"
                    [[ -n "$token" ]] && items+=("$token")
                done
                case "$in_array" in
                    L3_TARGETS) L3_TARGETS=("${items[@]}") ;;
                    L3_TARGETS_V6) L3_TARGETS_V6=("${items[@]}") ;;
                    IGNORED_INTERFACES) IGNORED_INTERFACES=("${items[@]}") ;;
                    MANAGED_INTERFACES) MANAGED_INTERFACES=("${items[@]}") ;;
                esac
                in_array=""
                array_buffer=""
            else
                local clean_line="${line%%#*}"
                array_buffer+=" ${clean_line}"
            fi
            continue
        fi

        if [[ "$line" =~ $pat_override ]]; then
            INTERFACE_WEIGHTS["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
            continue
        fi

        if [[ "$line" =~ $pat_array_single ]]; then
            local arr_var="${BASH_REMATCH[1]}"
            local arr_raw="${BASH_REMATCH[2]}"
            arr_raw="${arr_raw%%#*}"
            local items=()
            local raw_items
            IFS=$' \t\n' read -r -a raw_items <<< "$arr_raw"
            for token in "${raw_items[@]}"; do
                token="${token%,}"
                token="${token%\"}"
                token="${token#\"}"
                token="${token%\'}"
                token="${token#\'}"
                [[ -n "$token" ]] && items+=("$token")
            done
            case "$arr_var" in
                L3_TARGETS) L3_TARGETS=("${items[@]}") ;;
                L3_TARGETS_V6) L3_TARGETS_V6=("${items[@]}") ;;
                IGNORED_INTERFACES) IGNORED_INTERFACES=("${items[@]}") ;;
                MANAGED_INTERFACES) MANAGED_INTERFACES=("${items[@]}") ;;
            esac
            continue
        fi

        if [[ "$line" =~ $pat_array_start ]]; then
            in_array="${BASH_REMATCH[1]}"
            local init_content="${BASH_REMATCH[2]}"
            init_content="${init_content%%#*}"
            array_buffer="${init_content}"
            continue
        fi

        if [[ "$line" =~ $pat_scalar ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"

            # Strip inline comments (unless quoted)
            if [[ "$val" =~ ^\"[^\"]*\" ]] || [[ "$val" =~ ^\'[^\']*\' ]]; then
                val=$(echo "$val" | sed -E "s/^([\"'].*[\"'])[[:space:]]*#.*$/\1/")
            else
                val="${val%%#*}"
            fi
            val="${val%"${val##*[![:space:]]}"}"

            if [[ "$val" =~ ^\"(.*)\"$ ]]; then
                val="${BASH_REMATCH[1]}"
            elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
                val="${BASH_REMATCH[1]}"
            fi

            case "$key" in
                CHECK_INTERVAL|L3_QUORUM|L3_TIMEOUT|L7_TIMEOUT|METRIC_PRIMARY|METRIC_BACKUP|METRIC_DEGRADED|THRESHOLD_FAIL|THRESHOLD_RECOVERY|WEIGHT_LAN|WEIGHT_USB|WEIGHT_WIFI|WEIGHT_WWAN|WEIGHT_OTHER)
                    if [[ "$val" =~ ^[0-9]+$ ]]; then
                        printf -v "$key" "%s" "$val"
                    fi
                    ;;
                L7_CHECK_ENABLED|DNS_SYNC_ENABLED|AUTO_CONFIG_RP_FILTER|ENABLE_IPV6|PROBE_LOCAL_GATEWAY|ADAPTIVE_PROBING)
                    if [[ "$val" == "true" || "$val" == "false" || "$val" == "auto" ]]; then
                        printf -v "$key" "%s" "$val"
                    fi
                    ;;
                L7_URL_*|L7_MSFT_EXPECTED|STATE_DIR|LOCK_FILE|LOG_LEVEL|MANAGED_INTERFACES)
                    if [[ ! "$val" =~ $pat_unsafe ]]; then
                        printf -v "$key" "%s" "$val"
                    fi
                    ;;
            esac
        fi
    done < "$file"
}

