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
# dnsmasq reads *.conf from this dir. We pin it as the dnsmasq instance's
# conf-dir via UCI (see ensure_dns_confdir) so the drop-in is honoured no matter
# which dnsmasq init ships: a stock OpenWrt init only loads the per-instance
# /tmp/dnsmasq.cfgXXXX.d, so an `opkg upgrade dnsmasq` that replaces a vendor
# init would otherwise silently stop reading this file -- and DNS would leak to
# the local WAN resolver with no error.
DNS_CONFDIR="/tmp/dnsmasq.d"
DNS_DROPIN="$DNS_CONFDIR/ts-lockdown.conf"
DNS_SERVERS="1.1.1.1 8.8.8.8"
LOCK_FILE="/var/lock/ts-lockdown.lock"
# '-w 10' waits up to 10s for the xtables lock instead of failing. Needed even
# with flock below, because fw3 runs its own iptables concurrently during the
# reload that invokes us (flock only serialises OUR instances, not fw3's).
# The '-w <seconds>' form is accepted by this build (verified: iptables -w 5).
IPT="iptables -w 10"
IP6T="ip6tables -w 10"

# Optional local override, kept OUT of the public repo: set DNS_SERVERS (e.g. to
# your own tailnet AdGuard resolver) in /etc/ts-lockdown.conf. It is a separate
# file, so it survives redeploys of this script and never carries private IPs
# into version control.
# shellcheck source=/dev/null
[ -r /etc/ts-lockdown.conf ] && . /etc/ts-lockdown.conf

log() { logger -t ts-lockdown "$@"; }

# Write the dnsmasq drop-in. Returns 0 if the file content changed (caller then
# reloads dnsmasq), 1 if it was already current -- so editing DNS_SERVERS now
# takes effect on the next reconcile, without a manual Tailscale toggle, while a
# steady-state run never reloads dnsmasq.
dns_apply() {
    mkdir -p "$DNS_CONFDIR"
    new="$(printf 'no-resolv\n'; for s in $DNS_SERVERS; do printf 'server=%s\n' "$s"; done)"
    [ "$new" = "$(cat "$DNS_DROPIN" 2>/dev/null)" ] && return 1
    printf '%s\n' "$new" > "$DNS_DROPIN"
    return 0
}
# Returns 0 if it removed the drop-in (caller reloads dnsmasq), 1 if none existed.
dns_clear() { [ -f "$DNS_DROPIN" ] && { rm -f "$DNS_DROPIN"; return 0; }; return 1; }

# Pin dnsmasq's conf-dir to DNS_CONFDIR so it actually loads our drop-in. Returns
# 0 if it had to (re)pin it (caller reloads dnsmasq), 1 if already correct. A
# no-op on a healthy router; self-heals a confdir lost to a dnsmasq/init upgrade.
# Same `option confdir` mechanism GL already uses for its own wgclient instance.
ensure_dns_confdir() {
    [ "$(uci -q get 'dhcp.@dnsmasq[0].confdir')" = "$DNS_CONFDIR" ] && return 1
    uci set "dhcp.@dnsmasq[0].confdir=$DNS_CONFDIR"
    uci commit dhcp
    log "pinned dnsmasq confdir=$DNS_CONFDIR (was unset or wrong)"
    return 0
}

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
transition=0
[ "$desired" != "$prev" ] && transition=1

# Reconcile DNS, then reload dnsmasq only if something that affects resolution
# changed: a state transition, a confdir (re)pin, or a drop-in content change.
# Each helper returns 1 when already correct, so a healthy router never reloads
# dnsmasq (no flap) while drift still self-heals on the next reconcile.
dns_changed=0
if [ "$desired" = "lockdown" ]; then
    ensure_dns_confdir && dns_changed=1
    dns_apply          && dns_changed=1
else
    dns_clear          && dns_changed=1
fi
if [ "$transition" = 1 ] || [ "$dns_changed" = 1 ]; then
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
fi

if [ "$transition" = 1 ]; then
    echo "$desired" > "$STATE_FILE"
    log "state -> $desired (wan_devs:$wan_devs exit:$exit_node_ip)"
fi

exit 0
