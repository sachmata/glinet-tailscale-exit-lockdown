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

# Persist the script across firmware upgrades
grep -qxF '/etc/firewall.ts-lockdown.sh' /etc/sysupgrade.conf 2>/dev/null \
    || echo '/etc/firewall.ts-lockdown.sh' >> /etc/sysupgrade.conf

echo "installed: include + sysupgrade entry"
