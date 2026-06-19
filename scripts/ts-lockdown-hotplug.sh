#!/bin/sh
# Installed as /etc/hotplug.d/iface/99-ts-lockdown
#
# Re-seal the kill switch whenever a (possibly new) WAN interface comes up.
#
# ts-lockdown derives its WAN egress devices at firewall-reload time. That
# covers boot, Tailscale toggles, and a WAN *mode* change (each triggers a
# reload). It does NOT cover a WAN that becomes active WITHOUT a firewall
# reload -- e.g. a hot-standby WAN winning the default route on failover, or a
# newly-plugged WAN with a name outside {wan,wwan,tethering,secondwan}. Until
# the next reload that device would be unsealed: a fail-OPEN leak window.
#
# This hook closes that gap by forcing a reconcile on every interface
# bring-up, so any newly-active WAN device is sealed immediately. The reconcile
# is idempotent and flock-serialised, so extra reloads are harmless. A firewall
# reload does not itself raise iface events, so there is no feedback loop.

[ "$ACTION" = "ifup" ] || [ "$ACTION" = "ifupdate" ] || exit 0

# Interfaces that are never a WAN egress -- skip to avoid needless reloads.
case "$INTERFACE" in
    loopback|lan|lan*) exit 0 ;;
esac
[ "$DEVICE" = "tailscale0" ] && exit 0

logger -t ts-lockdown "iface $ACTION ($INTERFACE/$DEVICE) -> firewall reload to re-seal WAN"
/etc/init.d/firewall reload >/dev/null 2>&1
