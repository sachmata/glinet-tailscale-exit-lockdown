#!/bin/sh
# Run ON the router. Idempotent installer for ts-lockdown.
set -e

# Register firewall include (named section for clean removal)
if [ -z "$(uci -q get firewall.ts_lockdown_include)" ]; then
    uci set firewall.ts_lockdown_include=include
fi
uci set firewall.ts_lockdown_include.type='script'
uci set firewall.ts_lockdown_include.path='/etc/firewall.ts-lockdown.sh'
uci set firewall.ts_lockdown_include.reload='1'
uci commit firewall

# Install WAN-bringup hotplug hook (re-seals the kill switch on failover or
# when a new WAN appears, without waiting for the next firewall reload).
if [ -f /tmp/ts-lockdown-hotplug.sh ]; then
    mkdir -p /etc/hotplug.d/iface
    cp /tmp/ts-lockdown-hotplug.sh /etc/hotplug.d/iface/99-ts-lockdown
    chmod +x /etc/hotplug.d/iface/99-ts-lockdown
fi

# Persist installed files across firmware upgrades
for f in /etc/firewall.ts-lockdown.sh /etc/hotplug.d/iface/99-ts-lockdown; do
    [ -f "$f" ] || continue
    grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf
done

echo "installed: include + hotplug hook + sysupgrade entries"
