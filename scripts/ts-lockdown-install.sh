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

# Install status / health-check helper
if [ -f /tmp/ts-lockdown-status.sh ]; then
    cp /tmp/ts-lockdown-status.sh /usr/sbin/ts-lockdown-status
    chmod +x /usr/sbin/ts-lockdown-status
fi

# Periodic backstop: re-runs the include ONLY when --check reports drift, so a
# healthy router is never disturbed but a missed hotplug/reload event still
# self-heals within the interval.
if [ -x /usr/sbin/ts-lockdown-status ]; then
    CRON_LINE='*/2 * * * * /usr/sbin/ts-lockdown-status --check >/dev/null 2>&1 || /etc/firewall.ts-lockdown.sh'
    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    grep -qxF "$CRON_LINE" /etc/crontabs/root || echo "$CRON_LINE" >> /etc/crontabs/root
    /etc/init.d/cron enable 2>/dev/null
    /etc/init.d/cron restart 2>/dev/null
fi

# Persist installed files across firmware upgrades
for f in /etc/firewall.ts-lockdown.sh /etc/hotplug.d/iface/99-ts-lockdown \
         /usr/sbin/ts-lockdown-status /etc/crontabs/root; do
    [ -f "$f" ] || continue
    grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf
done

echo "installed: include + hotplug hook + status helper + cron backstop + sysupgrade entries"
