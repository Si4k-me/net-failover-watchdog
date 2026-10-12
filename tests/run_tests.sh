#!/usr/bin/env bash
#
# tests/run_tests.sh
# Hermetic, repeatable test suite for net-failover-watchdog.
# Uses Linux user and network namespaces (unshare -r -n) for rootless, isolated validation.
#

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DAEMON="${PROJECT_ROOT}/net-failover-watchdog"

# Ensure test runs inside unshare if not already in an isolated namespace
if [[ -z "${IN_TEST_NAMESPACE:-}" ]]; then
    echo "============================================================"
    echo " Starting net-failover-watchdog Automated Test Suite"
    echo " Spawning isolated user & network namespace (unshare -r -n)..."
    echo "============================================================"
    export IN_TEST_NAMESPACE=1
    exec unshare -r -n bash "$0" "$@"
fi

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASSED_COUNT=0
FAILED_COUNT=0

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    (( PASSED_COUNT += 1 ))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    echo -e "       Details: $2"
    (( FAILED_COUNT += 1 ))
}

info() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

# Temporary workspace for test artifacts
TEST_TMP="$(mktemp -d /tmp/net-watchdog-test.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

TEST_STATE_DIR="${TEST_TMP}/state"
TEST_LOCK_FILE="${TEST_TMP}/lock.file"
TEST_BIN_DIR="${TEST_TMP}/bin"
mkdir -p "$TEST_STATE_DIR" "$TEST_BIN_DIR"

export PATH="${TEST_BIN_DIR}:${PATH}"

# Generate minimal test configuration
cat <<EOF > "${TEST_TMP}/test.conf"
CHECK_INTERVAL=1
L3_TARGETS=("1.1.1.1" "8.8.8.8")
L3_QUORUM=1
L3_TIMEOUT=1
L7_CHECK_ENABLED=false
METRIC_PRIMARY=50
METRIC_BACKUP=200
METRIC_DEGRADED=500
THRESHOLD_FAIL=3
THRESHOLD_RECOVERY=5
MANAGED_INTERFACES=("veth0" "veth1")
declare -A INTERFACE_WEIGHTS=( ["veth0"]=1 ["veth1"]=2 )
STATE_DIR="${TEST_STATE_DIR}"
LOCK_FILE="${TEST_LOCK_FILE}"
LOG_LEVEL="DEBUG"
AUTO_CONFIG_RP_FILTER=false
DNS_SYNC_ENABLED=true
EOF

# Helper to setup simulated veth interfaces
setup_veth_pair() {
    ip link del dev veth0 2>/dev/null || true
    ip link del dev veth1 2>/dev/null || true

    ip link add veth0 type veth peer name veth0_peer
    ip link add veth1 type veth peer name veth1_peer

    ip link set dev veth0 up
    ip link set dev veth0_peer up
    ip link set dev veth1 up
    ip link set dev veth1_peer up

    ip addr add 192.168.10.2/24 dev veth0
    ip addr add 192.168.20.2/24 dev veth1

    ip route add default via 192.168.10.1 dev veth0 metric 100
    ip route add default via 192.168.20.1 dev veth1 metric 101
}

# -----------------------------------------------------------------------------
# TEST 1: CLI Validation & Help / Version Flags
# -----------------------------------------------------------------------------
info "Test 1: CLI options (--help, --version, --status)"
if "$DAEMON" --help | grep -q "Usage: net-failover-watchdog" && \
   "$DAEMON" --version | grep -q "net-failover-watchdog v1.1.0"; then
    pass "CLI flags --help and --version report correct usage and version"
else
    fail "CLI flags --help or --version failed" "Unexpected output format"
fi

# -----------------------------------------------------------------------------
# TEST 2: Initial Route Reconciliation & Prioritization
# -----------------------------------------------------------------------------
info "Test 2: Initial Route Reconciliation & Prioritization"
setup_veth_pair

# Mock ping and curl so health checks pass
cat <<'EOF' > "${TEST_BIN_DIR}/ping"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TEST_BIN_DIR}/ping"

# Run a single reconciliation cycle
"$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1

# In test.conf, MANAGED_INTERFACES=("veth0" "veth1")
# veth0 has same classification weight as veth1 (WEIGHT_OTHER), so veth0 wins by order
veth0_metric=$(ip -4 route show default dev veth0 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
veth1_metric=$(ip -4 route show default dev veth1 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')

if [[ "$veth0_metric" == "50" && "$veth1_metric" == "200" ]]; then
    pass "Initial route reconciliation established primary (metric 50) and backup (metric 200)"
else
    fail "Initial route reconciliation failed" "veth0 metric: $veth0_metric, veth1 metric: $veth1_metric"
fi

# -----------------------------------------------------------------------------
# TEST 3: DHCP Renewal Rogue Route Invalidation
# -----------------------------------------------------------------------------
info "Test 3: DHCP Renewal Rogue Route Invalidation"
# Simulate a DHCP client lease renewal adding unmanaged default routes
ip route add default via 192.168.10.1 dev veth0 metric 100
ip route add default via 192.168.20.1 dev veth1 metric 0 2>/dev/null || ip route add default via 192.168.20.1 dev veth1

# Confirm rogue routes were inserted
rogue_count=$(ip -4 route show default | grep -E "metric 100|dev veth1$" | wc -l)
if [[ "$rogue_count" -ge 1 ]]; then
    # Run watchdog reconciliation cycle
    "$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1

    # Verify rogue routes are purged and only authorized metrics (50, 200) persist
    remaining_routes=$(ip -4 route show default)
    if echo "$remaining_routes" | grep -qvE "metric (50|200)"; then
        fail "Rogue routes still present after reconciliation" "$remaining_routes"
    else
        pass "Watchdog purged rogue DHCP renewal routes and preserved target metrics"
    fi
else
    fail "Could not inject simulated DHCP rogue routes" "Kernel refused route add"
fi

# -----------------------------------------------------------------------------
# TEST 4: Duplicate Gateway Invalidation
# -----------------------------------------------------------------------------
info "Test 4: Duplicate Gateway Invalidation on Same Interface"
# Add a duplicate gateway with stale metric on veth0
ip route add default via 192.168.10.254 dev veth0 metric 300 2>/dev/null || true
"$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1

veth0_routes=$(ip -4 route show default dev veth0)
route_count=$(echo "$veth0_routes" | grep -c "default via" || true)

if [[ "$route_count" -eq 1 && "$veth0_routes" =~ metric\ 50 ]]; then
    pass "Duplicate gateway pruned; single authorized default route retained on interface"
else
    fail "Duplicate gateway not cleanly pruned" "$veth0_routes"
fi

# -----------------------------------------------------------------------------
# TEST 5: Failover Trigger (Demotion after THRESHOLD_FAIL cycles)
# -----------------------------------------------------------------------------
info "Test 5: Failover Trigger (Demotion on primary failure)"
# Mock ping to fail on veth0 and succeed on veth1
cat <<'EOF' > "${TEST_BIN_DIR}/ping"
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == "veth0" ]]; then
        exit 1
    fi
done
exit 0
EOF
chmod +x "${TEST_BIN_DIR}/ping"

# Reset state
rm -rf "${TEST_STATE_DIR:?}"/*

# Cycle 1: Failure 1 (Below threshold 3)
"$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1
c1_veth0=$(ip -4 route show default dev veth0 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')

# Cycle 2: Failure 2 (Below threshold 3)
"$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1
c2_veth0=$(ip -4 route show default dev veth0 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')

# Cycle 3: Failure 3 (Threshold met -> Demotion)
"$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1
c3_veth0=$(ip -4 route show default dev veth0 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
c3_veth1=$(ip -4 route show default dev veth1 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')

if [[ "$c1_veth0" == "50" && "$c2_veth0" == "50" && "$c3_veth0" == "500" && "$c3_veth1" == "50" ]]; then
    pass "Failover hysteresis verified: demoted veth0 (metric 500) and promoted veth1 (metric 50) on 3rd failure"
else
    fail "Failover hysteresis failed" "C1: $c1_veth0, C2: $c2_veth0, C3_veth0: $c3_veth0, C3_veth1: $c3_veth1"
fi

# -----------------------------------------------------------------------------
# TEST 6: Asymmetric Recovery Hysteresis (Gated by THRESHOLD_RECOVERY)
# -----------------------------------------------------------------------------
info "Test 6: Asymmetric Recovery Hysteresis"
# Now veth0 recovers (mock ping succeeds for both veth0 and veth1)
cat <<'EOF' > "${TEST_BIN_DIR}/ping"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TEST_BIN_DIR}/ping"

# In test.conf, THRESHOLD_RECOVERY=5
# Run 4 cycles: veth0 is recovering but has not met threshold of 5 successes
for i in {1..4}; do
    "$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1
done

interim_veth0=$(ip -4 route show default dev veth0 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
interim_veth1=$(ip -4 route show default dev veth1 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')

# Run 5th cycle: veth0 reaches 5 successes and should be promoted back
"$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1

recovered_veth0=$(ip -4 route show default dev veth0 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
recovered_veth1=$(ip -4 route show default dev veth1 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')

if [[ "$interim_veth0" == "200" && "$interim_veth1" == "50" && "$recovered_veth0" == "50" && "$recovered_veth1" == "200" ]]; then
    pass "Recovery hysteresis verified: link remained standby during gating, then safely reinstated on 5th success"
else
    fail "Recovery hysteresis failed" "Interim: veth0=$interim_veth0, veth1=$interim_veth1 | Final: veth0=$recovered_veth0, veth1=$recovered_veth1"
fi

# -----------------------------------------------------------------------------
# TEST 7: Strict Reverse Path Filtering Warning Detection
# -----------------------------------------------------------------------------
info "Test 7: Strict Reverse Path Filtering Detection"
if [[ -w /proc/sys/net/ipv4/conf/all/rp_filter ]]; then
    echo 1 > /proc/sys/net/ipv4/conf/all/rp_filter
    echo 1 > /proc/sys/net/ipv4/conf/veth0/rp_filter
    rm -f "${TEST_STATE_DIR}"/*.rp_warned

    output=$("$DAEMON" -c "${TEST_TMP}/test.conf" --once 2>&1 || true)
    if echo "$output" | grep -q "Strict Reverse Path Filtering (rp_filter=1)"; then
        pass "Strict rp_filter successfully detected and logged warning"
    else
        fail "Strict rp_filter warning not detected in log output" "$output"
    fi
else
    pass "Skipping rp_filter write test (user namespace has read-only /proc/sys)"
fi

# -----------------------------------------------------------------------------
# TEST 8: Point-to-Point / Device Default Routes (No Gateway)
# -----------------------------------------------------------------------------
info "Test 8: Point-to-Point / Device Default Routes"
ip route del default dev veth0 2>/dev/null || true
ip route add default dev veth0 metric 100

output=$("$DAEMON" -c "${TEST_TMP}/test.conf" --once 2>&1 || true)
veth0_dev_metric=$(ip -4 route show default dev veth0 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')

if [[ "$veth0_dev_metric" == "50" ]]; then
    pass "Point-to-point / direct device default route reconciled to metric 50 without errors"
else
    fail "Point-to-point default route failed" "veth0 metric: $veth0_dev_metric | Output: $output"
fi

# -----------------------------------------------------------------------------
# TEST 9: Systemd-Resolved Synchronization Mock
# -----------------------------------------------------------------------------
info "Test 9: Systemd-Resolved Synchronization Mock"
RESOLVECTL_LOG="${TEST_TMP}/resolvectl.log"
rm -f "${RESOLVECTL_LOG}" "${TEST_STATE_DIR}/primary.dns"
cat <<EOF > "${TEST_BIN_DIR}/resolvectl"
#!/usr/bin/env bash
echo "\$@" >> "${RESOLVECTL_LOG}"
exit 0
EOF
chmod +x "${TEST_BIN_DIR}/resolvectl"

"$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1

active_primary=$(ip -4 route show default | awk '$0 ~ /metric 50/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
active_backup=$(ip -4 route show default | awk '$0 ~ /metric 200/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')

if [[ -n "$active_primary" ]] && \
   grep -q "default-route ${active_primary} yes" "$RESOLVECTL_LOG" && \
   grep -q "flush-caches" "$RESOLVECTL_LOG"; then
    # Run second cycle with same primary and ensure flush-caches is NOT called redundantly
    flush_count_before=$(grep -c "flush-caches" "$RESOLVECTL_LOG" || echo 0)
    "$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1
    flush_count_after=$(grep -c "flush-caches" "$RESOLVECTL_LOG" || echo 0)

    if [[ "$flush_count_after" -eq "$flush_count_before" ]]; then
        pass "DNS resolvectl default-route synchronization and change-only cache flushing confirmed"
    else
        fail "DNS cache flush was called redundantly when primary did not change" "Before: $flush_count_before, After: $flush_count_after"
    fi
else
    fail "DNS resolvectl calls did not match expected sequence" "$(cat "$RESOLVECTL_LOG" 2>/dev/null || echo 'empty')"
fi

# -----------------------------------------------------------------------------
# TEST 10: Dry-Run Mode Validation
# -----------------------------------------------------------------------------
info "Test 10: Dry-Run Mode Validation"
# Add a rogue metric 100 route
ip route add default via 192.168.10.1 dev veth0 metric 100 2>/dev/null || true

# Run with --dry-run
"$DAEMON" -c "${TEST_TMP}/test.conf" --dry-run --once >/dev/null 2>&1

# In dry-run mode, the route table must NOT be modified
if ip -4 route show default dev veth0 | grep -q "metric 100"; then
    pass "Dry-run mode confirmed: routing table preserved without alterations"
else
    fail "Dry-run modified the routing table unexpectedly" "$(ip -4 route show default dev veth0)"
fi

# -----------------------------------------------------------------------------
# TEST 11: Dynamic Priority Reconfiguration via CLI & SIGHUP Reload
# -----------------------------------------------------------------------------
info "Test 11: Dynamic Priority Reconfiguration via CLI & SIGHUP Reload"
CTL="${PROJECT_ROOT}/net-failover-watchdog-ctl"
TEST_DROP_IN="${TEST_TMP}/drop-in"
mkdir -p "$TEST_DROP_IN"

# Reset veth routing table: veth0 primary (50), veth1 backup (200)
setup_veth_pair
"$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1

# Verify veth0 is primary (50) and veth1 is backup (200)
pre_v0=$(ip -4 route show default dev veth0 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
pre_v1=$(ip -4 route show default dev veth1 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')

if [[ "$pre_v0" == "50" && "$pre_v1" == "200" ]]; then
    # Start daemon in continuous background loop
    CONFIG_FILE="${TEST_TMP}/test.conf" DROP_IN_DIR="${TEST_DROP_IN}" \
    "$DAEMON" -c "${TEST_TMP}/test.conf" >/dev/null 2>&1 &
    DAEMON_PID=$!
    sleep 0.5

    # Change priority via CTL: invert priority so veth1 is higher than veth0
    CONFIG_FILE="${TEST_TMP}/test.conf" DROP_IN_DIR="${TEST_DROP_IN}" \
    "$CTL" priority set "veth1 > veth0" >/dev/null 2>&1

    # Signal daemon PID with reload signals
    kill -USR1 "$DAEMON_PID" 2>/dev/null || true
    kill -HUP "$DAEMON_PID" 2>/dev/null || true
    sleep 2

    # Stop daemon
    kill -TERM "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true

    post_v0=$(ip -4 route show default dev veth0 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
    post_v1=$(ip -4 route show default dev veth1 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')

    if [[ "$post_v1" == "50" && "$post_v0" == "200" ]]; then
        pass "Dynamic priority inversion verified: veth1 promoted to metric 50 upon reload"
    else
        fail "Dynamic priority reload failed" "veth0: $post_v0, veth1: $post_v1 (expected veth1=50, veth0=200)"
    fi
else
    fail "Pre-condition failed for Test 11" "veth0: $pre_v0, veth1: $pre_v1"
fi

# -----------------------------------------------------------------------------
# TEST 12: CLI Priority Reset & Reversion to Defaults
# -----------------------------------------------------------------------------
info "Test 12: CLI Priority Reset & Reversion to Defaults"
CONFIG_FILE="${TEST_TMP}/test.conf" DROP_IN_DIR="${TEST_DROP_IN}" \
"$CTL" priority reset >/dev/null 2>&1

if [[ ! -f "${TEST_DROP_IN}/priority.conf" ]]; then
    # Run once to apply defaults (veth0=1, veth1=2 in test.conf)
    DROP_IN_DIR="${TEST_DROP_IN}" "$DAEMON" -c "${TEST_TMP}/test.conf" --once >/dev/null 2>&1
    revert_v0=$(ip -4 route show default dev veth0 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
    revert_v1=$(ip -4 route show default dev veth1 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')

    if [[ "$revert_v0" == "50" && "$revert_v1" == "200" ]]; then
        pass "Priority reset verified: drop-in removed and default hierarchy restored"
    else
        fail "Priority reset failed to restore default routes" "veth0: $revert_v0, veth1: $revert_v1"
    fi
else
    fail "Priority reset did not delete priority.conf" "${TEST_DROP_IN}/priority.conf persists"
fi

# -----------------------------------------------------------------------------
# TEST 13: Configuration File Security Ingestion Guard
# -----------------------------------------------------------------------------
info "Test 13: Configuration Security Validation (Reject Malicious Command Substitution)"
INSECURE_CONF="${TEST_TMP}/insecure.conf"
cat <<EOF > "$INSECURE_CONF"
CHECK_INTERVAL=1
EXPLOIT=\$(touch "${TEST_TMP}/should_not_exist")
EOF

sec_output=$("$DAEMON" -c "$INSECURE_CONF" --once 2>&1 || true)
if [[ ! -f "${TEST_TMP}/should_not_exist" ]] && echo "$sec_output" | grep -q "Refusing to load insecure configuration"; then
    pass "Configuration security verified: disallowed command substitution rejected without execution"
else
    fail "Configuration security failed" "File was executed or warning missing. Output: $sec_output"
fi

# -----------------------------------------------------------------------------
# TEST 14: Space-separated and Quoted Priority CLI Commands
# -----------------------------------------------------------------------------
info "Test 14: Non-hostile Shell Priority Syntax (Space-separated & Quoted '>')"
CONFIG_FILE="${TEST_TMP}/test.conf" DROP_IN_DIR="${TEST_DROP_IN}" \
"$CTL" priority set veth1 veth0 >/dev/null 2>&1

if grep -q 'INTERFACE_WEIGHTS\["veth1"\]=1' "${TEST_DROP_IN}/priority.conf" 2>/dev/null && \
   grep -q 'INTERFACE_WEIGHTS\["veth0"\]=2' "${TEST_DROP_IN}/priority.conf" 2>/dev/null; then
    pass "Space-separated priority CLI syntax verified without requiring shell redirection operators"
else
    fail "Space-separated priority CLI syntax failed" "$(cat "${TEST_DROP_IN}/priority.conf" 2>/dev/null || echo 'missing')"
fi

# -----------------------------------------------------------------------------
# TEST 15: IPv6 Dual-Stack Default Route Synchronization
# -----------------------------------------------------------------------------
info "Test 15: IPv6 Dual-Stack Default Route Metric Synchronization"
ip -6 addr add 2001:db8:10::2/64 dev veth0 2>/dev/null || true
ip -6 addr add 2001:db8:20::2/64 dev veth1 2>/dev/null || true
ip -6 route add default via 2001:db8:10::1 dev veth0 metric 1024 2>/dev/null || true
ip -6 route add default via 2001:db8:20::1 dev veth1 metric 1024 2>/dev/null || true

V6_CONF="${TEST_TMP}/v6_test.conf"
cp "${TEST_TMP}/test.conf" "$V6_CONF"
echo "ENABLE_IPV6=true" >> "$V6_CONF"

rm -f "${TEST_DROP_IN}/priority.conf"
"$DAEMON" -c "$V6_CONF" --once >/dev/null 2>&1

v6_metric_v0=$(ip -6 route show default dev veth0 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
v6_metric_v1=$(ip -6 route show default dev veth1 | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')

if [[ "$v6_metric_v0" == "50" && "$v6_metric_v1" == "200" ]]; then
    pass "IPv6 default route metrics synchronized: veth0 promoted to 50, veth1 to 200"
else
    fail "IPv6 default route synchronization failed" "veth0: $v6_metric_v0 (expected 50), veth1: $v6_metric_v1 (expected 200)"
fi

# -----------------------------------------------------------------------------
# TEST 16: Pure Declarative Parser Immunity (No Command Execution)
# -----------------------------------------------------------------------------
info "Test 16: Pure Declarative Config Parser Shell Injection Immunity"
INJECTION_CONF="${TEST_TMP}/injection.conf"
cat <<EOF > "$INJECTION_CONF"
CHECK_INTERVAL=2
MALICIOUS_CMD=\$(touch "${TEST_TMP}/exploit_marker")
WEIGHT_LAN=1; touch "${TEST_TMP}/exploit_marker2"
EOF

# Parse via common library directly
source "$COMMON_LIB"
parse_declarative_config "$INJECTION_CONF"

if [[ ! -f "${TEST_TMP}/exploit_marker" && ! -f "${TEST_TMP}/exploit_marker2" && "$CHECK_INTERVAL" == "2" ]]; then
    pass "Declarative config parser parsed valid keys and neutralized shell injection without execution"
else
    fail "Declarative config parser permitted execution of injected command" "Marker file was created"
fi

# -----------------------------------------------------------------------------
# TEST 17: Parser Comprehensive Edge-Case Matrix
# -----------------------------------------------------------------------------
info "Test 17: Declarative Config Parser Edge-Case Matrix"
EDGE_CONF="${TEST_TMP}/edge.conf"
cat <<'EOF' > "$EDGE_CONF"
# Spacing around assignment operators
CHECK_INTERVAL   =   5 # trailing comment
METRIC_PRIMARY = 50 # primary metric
L7_MSFT_EXPECTED = "Microsoft Connect Test" # quoted string

# Multiline array with individual element comments and commas
IGNORED_INTERFACES=(
    "lo" # loopback device
    "docker*" # docker bridge
    "wg*", # wireguard vpn
)

# Array with single quotes and commas
L3_TARGETS=('1.1.1.1', '8.8.8.8')

# Per-interface weight overrides with varied quoting and spacing
INTERFACE_WEIGHTS["veth0"] = 1
INTERFACE_WEIGHTS['veth1'] = 2

# Unrecognized variable (must be safely ignored without errors)
UNKNOWN_ARBITRARY_OPTION = "should_be_ignored"
EOF

# Parse via declarative parser
declare -A INTERFACE_WEIGHTS=()
IGNORED_INTERFACES=()
L3_TARGETS=()
parse_declarative_config "$EDGE_CONF"

if [[ "$CHECK_INTERVAL" == "5" && \
      "$METRIC_PRIMARY" == "50" && \
      "$L7_MSFT_EXPECTED" == "Microsoft Connect Test" && \
      "${#IGNORED_INTERFACES[@]}" -eq 3 && \
      "${IGNORED_INTERFACES[0]}" == "lo" && \
      "${IGNORED_INTERFACES[1]}" == "docker*" && \
      "${IGNORED_INTERFACES[2]}" == "wg*" && \
      "${#L3_TARGETS[@]}" -eq 2 && \
      "${L3_TARGETS[0]}" == "1.1.1.1" && \
      "${L3_TARGETS[1]}" == "8.8.8.8" && \
      "${INTERFACE_WEIGHTS[veth0]}" == "1" && \
      "${INTERFACE_WEIGHTS[veth1]}" == "2" ]]; then
    pass "Declarative parser successfully handled all whitespace, quoting, comment, and array edge cases"
else
    fail "Declarative parser failed edge-case matrix" "Values: CHECK_INTERVAL=$CHECK_INTERVAL, IGNORED=${IGNORED_INTERFACES[*]}, L3=${L3_TARGETS[*]}, veth0=${INTERFACE_WEIGHTS[veth0]-none}, veth1=${INTERFACE_WEIGHTS[veth1]-none}"
fi

# -----------------------------------------------------------------------------
# TEST 18: Real Adaptive Backoff Verification
# -----------------------------------------------------------------------------
info "Test 18: Real Adaptive Probing Backoff for Persistently Failed Interfaces"
# Set veth0 as having 10 consecutive failures in state directory
mkdir -p "${TEST_STATE_DIR}"
echo "10" > "${TEST_STATE_DIR}/veth0.fails"

PROBE_LOG="${TEST_TMP}/adaptive_probe.log"
rm -f "$PROBE_LOG"

cat <<EOF > "${TEST_BIN_DIR}/ping"
#!/usr/bin/env bash
echo "ping called on \$*" >> "${PROBE_LOG}"
exit 1
EOF
chmod +x "${TEST_BIN_DIR}/ping"

# Cycle 1 (WATCHDOG_CYCLE_COUNT=1, mod 5 = 1 != 0): probe must be SKIPPED
ADAPTIVE_CONF="${TEST_TMP}/adaptive.conf"
cp "${TEST_TMP}/test.conf" "$ADAPTIVE_CONF"
echo "ADAPTIVE_PROBING=true" >> "$ADAPTIVE_CONF"

FORCE_ADAPTIVE_BACKOFF=true WATCHDOG_CYCLE_COUNT=0 "$DAEMON" -c "$ADAPTIVE_CONF" --once >/dev/null 2>&1
calls_on_skipped_cycle=$(grep -c "ping called on" "$PROBE_LOG" 2>/dev/null || echo 0)

# Cycle 5 (WATCHDOG_CYCLE_COUNT=4 + 1 = 5, mod 5 = 0): probe must be EXECUTED
WATCHDOG_CYCLE_COUNT=4 FORCE_ADAPTIVE_BACKOFF=true "$DAEMON" -c "$ADAPTIVE_CONF" --once >/dev/null 2>&1
calls_on_sampled_cycle=$(grep -c "ping called on" "$PROBE_LOG" 2>/dev/null || echo 0)

# Restore standard mock ping
cat <<'EOF' > "${TEST_BIN_DIR}/ping"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TEST_BIN_DIR}/ping"

if [[ "$calls_on_skipped_cycle" -eq 0 && "$calls_on_sampled_cycle" -gt 0 ]]; then
    pass "Real adaptive backoff confirmed: probes throttled on non-sampled cycles ($calls_on_skipped_cycle calls) and dispatched on sample interval ($calls_on_sampled_cycle calls)"
else
    fail "Adaptive backoff throttling failed" "Calls on skipped cycle: $calls_on_skipped_cycle (expected 0), sampled cycle: $calls_on_sampled_cycle (expected > 0)"
fi

echo "============================================================"
echo " Test Summary: ${PASSED_COUNT} Passed, ${FAILED_COUNT} Failed"
echo "============================================================"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0

