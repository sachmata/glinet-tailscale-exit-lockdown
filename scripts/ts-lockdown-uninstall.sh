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

# Remove files + hotplug hook + status helper + state + lock
rm -f /etc/firewall.ts-lockdown.sh /etc/hotplug.d/iface/99-ts-lockdown \
      /usr/sbin/ts-lockdown-status \
      /tmp/dnsmasq.d/ts-lockdown.conf /tmp/ts-lockdown.state /var/lock/ts-lockdown.lock

# Remove the cron backstop line (preserve any other cron entries the user has)
crontab_removed=0
if [ -f /etc/crontabs/root ]; then
    sed -i '\#ts-lockdown-status --check#d' /etc/crontabs/root
    if [ -s /etc/crontabs/root ]; then
        :   # other entries remain; leave the file and its persistence alone
    else
        rm -f /etc/crontabs/root
        crontab_removed=1
    fi
    /etc/init.d/cron restart 2>/dev/null
fi

# Remove sysupgrade entries (the crontab entry only if we deleted the file)
if [ -f /etc/sysupgrade.conf ]; then
    sed -i '\#^/etc/firewall.ts-lockdown.sh$#d' /etc/sysupgrade.conf
    sed -i '\#^/etc/hotplug.d/iface/99-ts-lockdown$#d' /etc/sysupgrade.conf
    sed -i '\#^/usr/sbin/ts-lockdown-status$#d' /etc/sysupgrade.conf
    [ "$crontab_removed" = 1 ] && sed -i '\#^/etc/crontabs/root$#d' /etc/sysupgrade.conf
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
