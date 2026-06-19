#!/bin/sh
# Run ON the router. Removes ts-lockdown and returns to stock GL behavior.
IPT="iptables -w 10"
IP6T="ip6tables -w 10"
TS_IF="tailscale0"
DNS_SERVERS="1.1.1.1 8.8.8.8"

# Remove firewall include (named section)
if [ -n "$(uci -q get firewall.ts_lockdown_include)" ]; then
    uci delete firewall.ts_lockdown_include
    uci commit firewall
fi

# Remove files + hotplug hook + state + lock
rm -f /etc/firewall.ts-lockdown.sh /etc/hotplug.d/iface/99-ts-lockdown \
      /tmp/dnsmasq.d/ts-lockdown.conf /tmp/ts-lockdown.state /var/lock/ts-lockdown.lock

# Remove sysupgrade entries
if [ -f /etc/sysupgrade.conf ]; then
    sed -i '\#^/etc/firewall.ts-lockdown.sh$#d' /etc/sysupgrade.conf
    sed -i '\#^/etc/hotplug.d/iface/99-ts-lockdown$#d' /etc/sysupgrade.conf
fi

# Tear down live chains (remove ALL jumps), then routes
while $IPT -D FORWARD -j ts_lockdown_fwd 2>/dev/null; do :; done
$IPT -F ts_lockdown_fwd 2>/dev/null; $IPT -X ts_lockdown_fwd 2>/dev/null
while $IP6T -D FORWARD -j ts_lockdown_fwd 2>/dev/null; do :; done
$IP6T -F ts_lockdown_fwd 2>/dev/null; $IP6T -X ts_lockdown_fwd 2>/dev/null
while $IPT -t nat -D POSTROUTING -j ts_lockdown_nat 2>/dev/null; do :; done
$IPT -t nat -F ts_lockdown_nat 2>/dev/null; $IPT -t nat -X ts_lockdown_nat 2>/dev/null
for s in $DNS_SERVERS; do ip route del "$s" dev "$TS_IF" 2>/dev/null; done

/etc/init.d/dnsmasq restart >/dev/null 2>&1
/etc/init.d/firewall restart >/dev/null 2>&1
echo "uninstalled: ts-lockdown removed; stock GL behavior restored"
