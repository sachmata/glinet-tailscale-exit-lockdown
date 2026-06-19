#!/bin/sh
# /etc/firewall.ts-lockdown.sh
#
# Fail-closed Tailscale exit-node lockdown for GL-MT3000.
# Registered as a fw3 firewall include (type=script, reload=1); runs on every
# firewall reload, which GL triggers at the end of every Tailscale toggle.
#
# LOCKDOWN (tailscale enabled AND an exit node selected):
#   * MASQUERADE LAN traffic into the tunnel (tailscale0)
#   * REJECT forwarded client traffic out any WAN device (v4+v6) => fail-closed
#   * Force DNS via public resolvers, routed through the tunnel (no local-WAN leak)
# NORMAL (otherwise): remove all of the above.
#
# Concurrency-safe: boot triggers several overlapping firewall reloads, so this
# script may be invoked concurrently. It (a) waits for the xtables lock via
# 'iptables -w', (b) serialises whole-script runs via flock -x (BusyBox
# compatible; blocks until exclusive lock acquired), and (c) removes ALL
# duplicate jumps in teardown so state always converges. Idempotent.

TS_IF="tailscale0"
NAT_CHAIN="ts_lockdown_nat"
FWD_CHAIN="ts_lockdown_fwd"
STATE_FILE="/tmp/ts-lockdown.state"
DNS_DROPIN="/tmp/dnsmasq.d/ts-lockdown.conf"
DNS_SERVERS="1.1.1.1 8.8.8.8"
LOCK_FILE="/var/lock/ts-lockdown.lock"
# '-w 10' waits up to 10s for the xtables lock instead of failing. Needed even
# with flock below, because fw3 runs its own iptables concurrently during the
# reload that invokes us (flock only serialises OUR instances, not fw3's).
# The '-w <seconds>' form is accepted by this build (verified: iptables -w 5).
IPT="iptables -w 10"
IP6T="ip6tables -w 10"

log() { logger -t ts-lockdown "$@"; }

dns_apply() {
    mkdir -p /tmp/dnsmasq.d
    {
        echo "no-resolv"
        for s in $DNS_SERVERS; do echo "server=$s"; done
    } > "$DNS_DROPIN"
}
dns_clear() { rm -f "$DNS_DROPIN"; }

# ---- desired state ----
enabled="$(uci -q get tailscale.settings.enabled)"
exit_node_ip="$(uci -q get tailscale.settings.exit_node_ip)"
if [ "$enabled" = "1" ] && [ -n "$exit_node_ip" ]; then
    desired="lockdown"
else
    desired="normal"
fi

# ---- WAN egress devices (derived at runtime) ----
# Primary: named WAN interfaces via ubus. Fallback: the actual default-route
# egress device(s) -- robust to ubus interface status lagging at boot, or a WAN
# that is not one of the names above. tailscale0 is never treated as WAN.
wan_devs=""
for net in wan wwan tethering secondwan; do
    d="$(ubus call network.interface.$net status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)"
    [ -n "$d" ] && [ "$d" != "$TS_IF" ] && wan_devs="$wan_devs $d"
done
for d in $(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'); do
    [ "$d" = "$TS_IF" ] && continue
    case " $wan_devs " in *" $d "*) ;; *) wan_devs="$wan_devs $d" ;; esac
done
[ "$desired" = "lockdown" ] && [ -z "$wan_devs" ] && log "WARNING: lockdown active but no WAN device resolved; kill switch cannot seal egress this run"

# ---- teardown (idempotent; removes ALL duplicate jumps) ----
fw_teardown() {
    while $IPT -t nat -D POSTROUTING -j "$NAT_CHAIN" 2>/dev/null; do :; done
    $IPT -t nat -F "$NAT_CHAIN" 2>/dev/null
    $IPT -t nat -X "$NAT_CHAIN" 2>/dev/null

    while $IPT -D FORWARD -j "$FWD_CHAIN" 2>/dev/null; do :; done
    $IPT -F "$FWD_CHAIN" 2>/dev/null
    $IPT -X "$FWD_CHAIN" 2>/dev/null

    while $IP6T -D FORWARD -j "$FWD_CHAIN" 2>/dev/null; do :; done
    $IP6T -F "$FWD_CHAIN" 2>/dev/null
    $IP6T -X "$FWD_CHAIN" 2>/dev/null

    for s in $DNS_SERVERS; do
        ip route del "$s" dev "$TS_IF" 2>/dev/null
    done
}

# ---- build lockdown rules ----
fw_build() {
    $IPT -t nat -N "$NAT_CHAIN" 2>/dev/null
    $IPT -t nat -F "$NAT_CHAIN"
    $IPT -t nat -A "$NAT_CHAIN" -o "$TS_IF" -j MASQUERADE
    $IPT -t nat -I POSTROUTING -j "$NAT_CHAIN"

    $IPT -N "$FWD_CHAIN" 2>/dev/null
    $IPT -F "$FWD_CHAIN"
    for d in $wan_devs; do
        $IPT -A "$FWD_CHAIN" -o "$d" -j REJECT --reject-with icmp-host-prohibited
    done
    $IPT -I FORWARD -j "$FWD_CHAIN"

    $IP6T -N "$FWD_CHAIN" 2>/dev/null
    $IP6T -F "$FWD_CHAIN" 2>/dev/null
    for d in $wan_devs; do
        $IP6T -A "$FWD_CHAIN" -o "$d" -j REJECT 2>/dev/null
    done
    $IP6T -I FORWARD -j "$FWD_CHAIN" 2>/dev/null

    # Route DNS resolvers through the tunnel so dnsmasq's upstream queries
    # egress via the exit node instead of the local WAN (no DNS leak).
    for s in $DNS_SERVERS; do
        ip route add "$s" dev "$TS_IF" 2>/dev/null
    done
}

# ---- reconcile (serialised: concurrent boot reloads must not interleave) ----
exec 9>"$LOCK_FILE"
# 'flock -x' blocks until the lock is free (BusyBox flock has no -w timeout), so
# it never fails on contention — concurrent boot reloads queue and run serially.
# The fallback below only triggers if 'exec 9>' itself failed to open the file.
flock -x 9 || { log "could not acquire lock; skipping reconcile"; exit 0; }

fw_teardown
if [ "$desired" = "lockdown" ]; then
    fw_build
fi

prev="$(cat "$STATE_FILE" 2>/dev/null)"
if [ "$desired" != "$prev" ]; then
    if [ "$desired" = "lockdown" ]; then dns_apply; else dns_clear; fi
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    echo "$desired" > "$STATE_FILE"
    log "state -> $desired (wan_devs:$wan_devs exit:$exit_node_ip)"
fi
