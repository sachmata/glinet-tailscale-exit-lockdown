#!/bin/sh
# Installed as /usr/sbin/ts-lockdown-status
#
#   ts-lockdown-status            human-readable health report
#   ts-lockdown-status --check    silent; exit 0 if healthy, 1 on drift
#
# --check is what the cron backstop runs: it reconciles (re-runs the include)
# ONLY when this reports drift, so a healthy router is never disturbed -- no
# rule flap, no traffic interruption -- and a missed hotplug/reload event still
# self-heals within the cron interval.
#
# The desired-state and WAN-derivation logic below MIRRORS
# /etc/firewall.ts-lockdown.sh; keep them in sync if that script changes.

TS_IF="tailscale0"
NAT_CHAIN="ts_lockdown_nat"
FWD_CHAIN="ts_lockdown_fwd"
STATE_FILE="/tmp/ts-lockdown.state"
DNS_DROPIN="/tmp/dnsmasq.d/ts-lockdown.conf"
IPT="iptables -w 5"
IP6T="ip6tables -w 5"

mode="report"
[ "$1" = "--check" ] && mode="check"

# ---- desired state (mirror of the include) ----
enabled="$(uci -q get tailscale.settings.enabled)"
exit_node_ip="$(uci -q get tailscale.settings.exit_node_ip)"
if [ "$enabled" = "1" ] && [ -n "$exit_node_ip" ]; then desired="lockdown"; else desired="normal"; fi

# ---- WAN egress devices (mirror of the include) ----
wan_devs=""
for net in wan wwan tethering secondwan; do
    d="$(ubus call network.interface.$net status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)"
    [ -n "$d" ] && [ "$d" != "$TS_IF" ] && wan_devs="$wan_devs $d"
done
for d in $(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'); do
    [ "$d" = "$TS_IF" ] && continue
    case " $wan_devs " in *" $d "*) ;; *) wan_devs="$wan_devs $d" ;; esac
done
wan_devs="$(echo "$wan_devs" | sed 's/^ *//;s/ *$//')"

# ---- gather actual ----
has_masq=0
$IPT -t nat -S "$NAT_CHAIN" 2>/dev/null | grep -q -- "-o $TS_IF -j MASQUERADE" && has_masq=1
nat_jumps=$($IPT -t nat -S POSTROUTING 2>/dev/null | grep -c -- "-j $NAT_CHAIN")
fwd4_jumps=$($IPT -S FORWARD 2>/dev/null | grep -c -- "-j $FWD_CHAIN")
fwd6_jumps=$($IP6T -S FORWARD 2>/dev/null | grep -c -- "-j $FWD_CHAIN")
state="$(cat "$STATE_FILE" 2>/dev/null)"

unsealed=""
for d in $wan_devs; do
    s4=0; $IPT  -S "$FWD_CHAIN" 2>/dev/null | grep -q -- "-o $d -j REJECT" && s4=1
    s6=0; $IP6T -S "$FWD_CHAIN" 2>/dev/null | grep -q -- "-o $d -j REJECT" && s6=1
    { [ "$s4" = 1 ] && [ "$s6" = 1 ]; } || unsealed="$unsealed $d"
done
unsealed="$(echo "$unsealed" | sed 's/^ *//;s/ *$//')"

# ---- compute drift ----
drift=""
add_drift() { drift="${drift:+$drift; }$1"; }
if [ "$desired" = "normal" ]; then
    { [ "$nat_jumps" -eq 0 ] && [ "$fwd4_jumps" -eq 0 ] && [ "$fwd6_jumps" -eq 0 ]; } \
        || add_drift "lockdown rules present but desired=normal"
else
    [ "$state" = "lockdown" ]  || add_drift "state='$state' (want lockdown)"
    [ "$has_masq" = 1 ]        || add_drift "masquerade rule missing"
    [ "$nat_jumps"  -eq 1 ]    || add_drift "POSTROUTING jumps=$nat_jumps (want 1)"
    [ "$fwd4_jumps" -eq 1 ]    || add_drift "FORWARD v4 jumps=$fwd4_jumps (want 1)"
    [ "$fwd6_jumps" -eq 1 ]    || add_drift "FORWARD v6 jumps=$fwd6_jumps (want 1)"
    # A missing WAN device at boot (e.g. WISP still associating) is NOT drift:
    # the include itself defers sealing until a device exists. Only flag a WAN
    # that is present yet unsealed.
    { [ -z "$wan_devs" ] || [ -z "$unsealed" ]; } || add_drift "unsealed WAN:$unsealed"
fi

# ---- check mode: silent verdict ----
if [ "$mode" = "check" ]; then
    [ -z "$drift" ] && exit 0 || exit 1
fi

# ---- report mode ----
# markif <0-or-1> <label>: 1 => OK line, 0 => WARN line
markif() {
    if [ "$1" = 1 ]; then printf '  [ OK ]  %s\n' "$2"; else printf '  [WARN]  %s\n' "$2"; fi
}
tsif_up=0; ip link show "$TS_IF" >/dev/null 2>&1 && tsif_up=1

echo "Tailscale exit-node lockdown -- status"
echo "  desired:      $desired (enabled=${enabled:-unset} exit_node_ip=${exit_node_ip:-unset})"
echo "  state file:   ${state:-<none>}"
echo "  WAN devices:  ${wan_devs:-<none resolved>}"
echo "  tailscale0:   $([ "$tsif_up" = 1 ] && echo up || echo down)"
echo
if [ "$desired" = "lockdown" ]; then
    markif "$has_masq" "masquerade -> $TS_IF"
    markif "$([ "$nat_jumps"  -eq 1 ] && echo 1 || echo 0)" "POSTROUTING jump x1 (have $nat_jumps)"
    markif "$([ "$fwd4_jumps" -eq 1 ] && echo 1 || echo 0)" "FORWARD v4 jump x1 (have $fwd4_jumps)"
    markif "$([ "$fwd6_jumps" -eq 1 ] && echo 1 || echo 0)" "FORWARD v6 jump x1 (have $fwd6_jumps)"
    if [ -z "$wan_devs" ]; then
        markif 0 "no WAN device yet -- kill switch deferred (safe: no egress path)"
    elif [ -z "$unsealed" ]; then
        markif 1 "kill switch sealed (v4+v6): $wan_devs"
    else
        markif 0 "WAN present but UNSEALED: $unsealed"
    fi
    markif "$([ -f "$DNS_DROPIN" ] && echo 1 || echo 0)" "DNS drop-in present"
else
    if [ "$nat_jumps" -eq 0 ] && [ "$fwd4_jumps" -eq 0 ] && [ "$fwd6_jumps" -eq 0 ]; then
        markif 1 "no lockdown rules present (normal mode)"
    else
        markif 0 "stray lockdown rules present"
    fi
fi
echo
backstop="$(grep -l 'ts-lockdown-status --check' /etc/crontabs/root 2>/dev/null)"
echo "  cron backstop: $([ -n "$backstop" ] && echo 'installed' || echo 'NOT installed')"
echo "  recent log:"
logread 2>/dev/null | grep ts-lockdown | tail -3 | sed 's/^/    /'
echo
if [ -z "$drift" ]; then
    echo "VERDICT: healthy"
else
    echo "VERDICT: DRIFT -> $drift"
    echo "  (the cron backstop will reconcile; or run: /etc/firewall.ts-lockdown.sh)"
fi
