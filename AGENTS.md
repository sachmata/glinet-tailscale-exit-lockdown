# AGENTS.md — deploying & testing on a real router

Operational runbook for an agent working on this repo. The deliverable is a
**fail-closed Tailscale exit-node lockdown** for GL.iNet (OpenWrt/`fw3`) routers.
"Done" means *verified on hardware*, not just edited locally — egress IP alone
does **not** prove correctness (see the home-network gotcha below).

## Repo layout

| File | Role |
|---|---|
| `scripts/firewall.ts-lockdown.sh` | The reconciling fw3 include. Installs to `/etc/firewall.ts-lockdown.sh`. Derives every WAN device at runtime and seals each (v4+v6). |
| `scripts/ts-lockdown-hotplug.sh` | WAN-bringup hook. Installs to `/etc/hotplug.d/iface/99-ts-lockdown`. Re-seals on failover / new WAN. |
| `scripts/ts-lockdown-status.sh` | Health helper. Installs to `/usr/sbin/ts-lockdown-status`. Report mode + `--check` (silent 0/1). Mirrors the include's desired-state/WAN-derivation logic — keep in sync. |
| `scripts/ts-lockdown-install.sh` | Idempotent on-router installer (run from `/tmp`). Registers the include, places the hook + status helper, adds the cron backstop, persists all in `/etc/sysupgrade.conf`. |
| `scripts/ts-lockdown-uninstall.sh` | Removes everything (preserving unrelated cron entries), restores stock GL behavior. |
| `scripts/ts-testclient.sh` | Creates a throwaway netns "LAN client" on the router for egress/DNS tests over SSH. |
| cron backstop | `*/2 * * * *` entry in `/etc/crontabs/root`: runs `ts-lockdown-status --check` and re-runs the include only on drift. |
| `docs/DESIGN.md` | Full design rationale, failure handling, scope. |

## Prerequisites

- Root SSH to the router (default `root@192.168.8.1`). Management plane is on the
  LAN (INPUT path) and is never touched by the kill switch, so SSH stays up.
- `scp` to the router may require the **legacy protocol flag**: use `scp -O ...`.
- The router's SSH may emit a post-quantum warning to stderr — it is harmless
  noise. Filter it in scripted runs:
  `... 2>&1 | grep -v -iE 'post-quantum|store now|openssh.com/pq|vulnerable|upgraded'`
- Target firmware is `fw3`/iptables. `fw4`/nftables is unverified — check first:
  `ssh root@192.168.8.1 'command -v fw3 || echo NO-FW3'`.

## Lint locally before deploying (CI gate)

CI runs `shellcheck scripts/*.sh` and scripts target POSIX `/bin/sh` (BusyBox ash).
Reproduce locally:

```sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable scripts/*.sh
for f in scripts/*.sh; do sh -n "$f"; done   # POSIX syntax check
```

## Deploy to the router

```sh
scp -O scripts/firewall.ts-lockdown.sh root@192.168.8.1:/etc/firewall.ts-lockdown.sh
scp -O scripts/ts-lockdown-hotplug.sh  root@192.168.8.1:/tmp/
scp -O scripts/ts-lockdown-install.sh  root@192.168.8.1:/tmp/
ssh root@192.168.8.1 'chmod +x /etc/firewall.ts-lockdown.sh; sh /tmp/ts-lockdown-install.sh; /etc/init.d/firewall reload'
```

Verify the install landed and is persisted:

```sh
ssh root@192.168.8.1 '
  ls -l /etc/firewall.ts-lockdown.sh /etc/hotplug.d/iface/99-ts-lockdown
  grep ts-lockdown /etc/sysupgrade.conf
  cat /tmp/ts-lockdown.state'   # -> "lockdown" when an exit node is selected
```

## Test suite (run on hardware)

Lockdown engages only when `tailscale.settings.enabled=1` **and**
`tailscale.settings.exit_node_ip` is set. Check/select via the GL UI or:
`ssh root@192.168.8.1 'uci show tailscale.settings | grep -E "enabled|exit_node_ip"'`.

### 1. Baseline: WAN derivation + live ruleset

```sh
ssh root@192.168.8.1 '
  ip route show default
  for net in wan wwan tethering secondwan; do
    echo "$net -> $(ubus call network.interface.$net status 2>/dev/null | jsonfilter -e "@.l3_device")"
  done
  iptables -w -S ts_lockdown_fwd; ip6tables -w -S ts_lockdown_fwd
  iptables -w -t nat -S ts_lockdown_nat'
```
Expect: one `REJECT -o <wandev>` per active WAN device (v4 **and** v6), and a
`MASQUERADE -o tailscale0`. In WISP/repeater mode the WAN device is `apcli0`;
wired it is `eth0`.

### 2. Failover gap — hotplug hook re-seals (the reason the hook exists)

Simulate an unsealed WAN, then fire a **real** netifd iface event:

```sh
ssh root@192.168.8.1 '
  iptables -w -F ts_lockdown_fwd                         # simulate unsealed state
  ACTION=ifup INTERFACE=wwan DEVICE=apcli0 hotplug-call iface
  sleep 3
  iptables -w -S ts_lockdown_fwd                         # expect the REJECT re-sealed
  logread | grep ts-lockdown | tail -3'
```
Expect the chain re-populated and a log line `iface ifup (...) -> firewall reload`.
Note: `hotplug-call iface` also runs GL's other shipped iface scripts, which print
`Command failed: Not found` / `tunnel_id=` noise — **not** from this hook.

### 3. No churn — non-WAN events must skip

```sh
ssh root@192.168.8.1 '
  before=$(logread | grep -c "iface .* -> firewall reload")
  ACTION=ifup INTERFACE=lan DEVICE=br-lan       /etc/hotplug.d/iface/99-ts-lockdown
  ACTION=ifup INTERFACE=loopback DEVICE=lo      /etc/hotplug.d/iface/99-ts-lockdown
  ACTION=ifdown INTERFACE=wwan DEVICE=apcli0    /etc/hotplug.d/iface/99-ts-lockdown
  after=$(logread | grep -c "iface .* -> firewall reload")
  echo "before=$before after=$after (must be equal)"'
```

### 4. End-to-end egress path — DO NOT trust the egress IP alone

⚠️ **Home-network gotcha:** if you are physically at the same site as the home
exit node, the local WAN and the tunnel egress share the **same public IP**, so
`curl ifconfig.co` cannot distinguish tunnel from leak. Verify the **path** with
packet counters instead:

```sh
ssh root@192.168.8.1 '
  sh /tmp/ts-testclient.sh up >/dev/null 2>&1
  iptables -w -t nat -Z ts_lockdown_nat; iptables -w -Z ts_lockdown_fwd
  ip netns exec tsclient curl -s --max-time 15 -o /dev/null -w "http=%{http_code}\n" https://ifconfig.co
  echo "--- want: MASQUERADE -o tailscale0 incremented ---"
  iptables -w -t nat -L ts_lockdown_nat -v -n -x
  echo "--- want: REJECT -o <wandev> stays 0 (no leak) ---"
  iptables -w -L ts_lockdown_fwd -v -n -x
  sh /tmp/ts-testclient.sh down >/dev/null 2>&1'
```
Pass = `tailscale0` MASQUERADE packets > 0 **and** WAN-device REJECT packets == 0.
(`ts-testclient.sh` must be copied to `/tmp` first: `scp -O scripts/ts-testclient.sh root@192.168.8.1:/tmp/`.)

### 5. Fail-closed (gold standard, DISRUPTIVE — ask the user first)

Stopping `tailscaled` drops the live tunnel. With an exit node selected, client
traffic must **block** (no fallback to local WAN), then restore on restart:

```sh
ssh root@192.168.8.1 '
  /etc/init.d/tailscale stop
  sh /tmp/ts-testclient.sh up >/dev/null 2>&1
  ip netns exec tsclient curl -s --max-time 10 https://ifconfig.co; echo "exit=$? (nonzero=blocked, good)"
  sh /tmp/ts-testclient.sh down >/dev/null 2>&1
  /usr/bin/gl_tailscale restart'    # restores enabled + exit_node_ip from uci, reloads firewall
```

### 6. Self-heal backstop — drift detection + cron recovery

`--check` must return 1 on drift, and the cron backstop (`*/2`) must re-seal
without manual action:

```sh
ssh root@192.168.8.1 '
  ts-lockdown-status                       # expect VERDICT: healthy
  ts-lockdown-status --check; echo "healthy_exit=$?"   # expect 0
  iptables -w -F ts_lockdown_fwd           # introduce drift
  ts-lockdown-status --check; echo "drift_exit=$?"     # expect 1
  grep ts-lockdown /etc/crontabs/root      # confirm cron line present
  /etc/init.d/cron enabled && echo cron-enabled'
# then wait for the next even minute and re-check the chain is re-sealed:
ssh root@192.168.8.1 'iptables -w -S ts_lockdown_fwd | grep -c REJECT'   # -> 1
```
Note: `--check` is non-disruptive (read-only); only a *drift* result causes the
cron line to run the include. Verify no duplicate jumps after a heal
(`iptables -w -S FORWARD | grep -c ts_lockdown` == 1).

## Uninstall / reset

```sh
scp -O scripts/ts-lockdown-uninstall.sh root@192.168.8.1:/tmp/
ssh root@192.168.8.1 'sh /tmp/ts-lockdown-uninstall.sh'
```
Removes include + script + hook + sysupgrade entries + all chains/routes/state,
restarts dnsmasq and the firewall.

## Gotchas / invariants

- **Concurrency:** boot fires several overlapping firewall reloads. The include
  is `flock`-serialised and uses `iptables -w`; after any reload there must be
  **exactly one** FORWARD jump (v4 and v6) and one POSTROUTING jump — no empty
  chains, no duplicates. Verify with `iptables -w -S FORWARD | grep -c ts_lockdown`.
- **No `uci` firewall writes from the include** — committing firewall config from
  within a firewall-reload include causes a reload loop. Masquerade is owned via
  its own chain, not GL's zone.
- **IPv6 forwarded egress is REJECTed** (blocked), not tunneled — intentional, to
  prevent v6 leaks. Don't "fix" this without revisiting the design.
- **DNS:** lockdown forces dnsmasq to `DNS_SERVERS` (default `1.1.1.1 8.8.8.8`)
  with host routes via `tailscale0`. dnsmasq is bounced only on a real state
  transition (guarded by `/tmp/ts-lockdown.state`).
- Keep `docs/DESIGN.md` and `README.md` in sync with script behavior when changing
  scope (WAN derivation, kill-switch targets, hotplug triggers).
