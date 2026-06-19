# glinet-tailscale-exit-lockdown

[![ShellCheck](https://github.com/sachmata/glinet-tailscale-exit-lockdown/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/sachmata/glinet-tailscale-exit-lockdown/actions/workflows/shellcheck.yml)

Always-on, **fail-closed** Tailscale exit-node routing for GL.iNet (OpenWrt) travel routers —
automatic masquerade, a kill switch, and DNS-leak protection, via a single self-contained
firewall include. No vendor files are modified.

When you select a Tailscale exit node in the GL.iNet UI, all LAN client traffic is routed out
through that node, your egress IP becomes the exit node's IP, and — crucially — if the tunnel
ever drops, clients are **blocked rather than silently falling back to the local WAN**. It
re-applies itself automatically on every exit-node toggle and across reboots.

## The problem this solves

On GL.iNet firmware, selecting a Tailscale exit node routes LAN traffic into the tunnel but
**forwarding fails** — the exit node receives packets with private LAN source addresses it can't
return. The usual workaround is to flip on *Masquerading* for the `tailscale0` interface in the
LuCI advanced UI. But GL's integration **deletes and recreates the `tailscale0` firewall zone on
every Tailscale toggle**, so the masquerade setting is wiped each time you switch nodes — you have
to redo it by hand, every time.

Root cause: GL's `/etc/firewall.tailscale.sh` recreates the zone without `masq=1`. See
[`docs/DESIGN.md`](docs/DESIGN.md) for the full analysis.

## What it does

In **LOCKDOWN** (Tailscale enabled **and** an exit node selected):

- **Masquerade** — SNAT LAN traffic into `tailscale0` so forwarding through the exit node works.
- **Fail-closed kill switch** — REJECT forwarded client traffic out the WAN (IPv4 **and** IPv6).
  If the exit node is unreachable, clients lose internet rather than leaking out the local WAN.
- **DNS through the tunnel** — force `dnsmasq` to public resolvers (`1.1.1.1`/`8.8.8.8`) and route
  those queries through the exit node, so DNS does not leak to the local upstream resolver.

In **NORMAL** (Tailscale off, or no exit node): all of the above is cleanly removed.

It is implemented as a `fw3` firewall **include** that runs on every firewall reload — which GL
triggers at the end of every Tailscale toggle — so it reconciles automatically and is idempotent.

## How it works

A single reconcile script, `/etc/firewall.ts-lockdown.sh`, registered as a firewall include. On
each run it reads `tailscale.settings`, derives **every** WAN egress device at runtime (all of
`wan`/`wwan`/`tethering`/`secondwan` plus every current default-route device — works in wired,
WISP/repeater, and multi-WAN setups), and converges the ruleset to the desired state using its own
iptables chains (`ts_lockdown_nat`, `ts_lockdown_fwd`). It is:

- **Concurrency-safe** — boot fires several overlapping firewall reloads; the script uses
  `iptables -w`, serializes itself with `flock`, and removes duplicate jumps so state always
  converges (without this, concurrent runs leave empty chains = protection silently absent).
- **Multi-WAN aware** — it seals every WAN device it derives, and a WAN-bringup hotplug hook
  (`/etc/hotplug.d/iface/99-ts-lockdown`) forces a reconcile when a WAN comes up, so a failover or
  newly-plugged WAN is sealed immediately rather than leaking until the next firewall reload.
- **Self-healing** — a cron backstop (every 2 min) runs `ts-lockdown-status --check` and re-runs
  the include **only if it reports drift**, so a healthy router is never disturbed (no rule flap)
  but a missed reload/hotplug event still self-heals within the interval.
- **Observable** — `ts-lockdown-status` prints a health report (desired vs actual state, WAN
  devices, per-device seal status, jump counts, verdict); `--check` gives a silent 0/1 exit for
  scripting.
- **Persistent** — the script, hotplug hook, status helper, and cron entry are registered in
  `/etc/sysupgrade.conf` so they survive firmware upgrades.
- **Non-invasive** — no GL vendor files are edited.

## Requirements

- A GL.iNet router on `fw3`/iptables-based firmware (see [Tested on](#tested-on) for the exact
  device/firmware this was validated against).
- Tailscale configured and logged in, with an exit node available on your tailnet.
- Root SSH access to the router.

> **Note on `scp`:** the router's SSH server may require the legacy protocol flag — use
> `scp -O ...`.

## Tested on

| | |
|---|---|
| **Device** | GL.iNet GL-MT3000 (Beryl AX) |
| **Firmware** | GL.iNet 4.8.1 (OpenWrt, kernel 5.4.211) |
| **Firewall** | `fw3` / iptables |
| **Tailscale** | 1.80.3 |

Verified scenarios on the above:

- Exit-node selected → LAN clients egress via the exit node's IP, no manual LuCI masquerade step.
- Fail-closed kill switch → with `tailscaled` stopped (tunnel down, `tailscale0` gone), a LAN
  client's traffic is **blocked** (`curl` exit 7, no connection) instead of falling back to the
  local WAN. Confirmed at the packet level: the attempt incremented the `REJECT -o apcli0` counter
  (WISP/repeater mode), proving the leak was actively sealed rather than merely route-less.
- DNS forced through the tunnel → resolves correctly with **zero** DNS queries leaking to the
  local WAN.
- **Reboot persistence** → lockdown re-establishes automatically after a power cycle, no manual
  step. Observed boot timing on the test unit (WISP/repeater): lockdown state + `tailscale0`
  masquerade come up immediately, but the WAN (`apcli0`) had not yet associated to the upstream AP,
  so the boot firewall run logged `WARNING: no WAN device resolved` and *deferred* the kill-switch
  REJECT — fail-safe, since with no WAN device there is no egress path to leak out of. ~2.5 min
  later `apcli0` associated, the hotplug hook fired (`iface ifup (wwan/apcli0) -> firewall reload`),
  and the kill switch sealed automatically (v4+v6). See [Boot-time sealing](#boot-time-sealing).
- **WAN mode change** → kill switch re-derived the correct WAN device across a wired-WAN (`eth0`) →
  WISP/repeater (`apcli0`) transition.
- **Failover re-seal (hotplug)** → after flushing the kill-switch chain to simulate a newly-active
  WAN, a real `wwan` `ifup` event (`hotplug-call iface`) triggered a firewall reload that
  re-derived and re-sealed `apcli0` (v4+v6); non-WAN events (`lan`/`loopback`/`ifdown`) correctly
  triggered no reload.
- **Concurrency** → overlapping boot-time firewall reloads converge to a correct ruleset (no empty
  chains, no duplicate jumps).
- **Status helper** → after a clean install, `ts-lockdown-status` reported all checks `[ OK ]`
  (masquerade, jumps 1/1/1, `apcli0` sealed v4+v6, DNS drop-in) with `VERDICT: healthy`, and
  `ts-lockdown-status --check` exited `0`.
- **Self-heal backstop** → flushing the kill-switch chain to simulate drift made
  `ts-lockdown-status --check` return exit `1`; the next 2-minute cron tick (~45 s later) re-ran the
  include and re-sealed `apcli0` (v4+v6) **automatically** — no manual step. Post-heal: `--check`
  back to `0`, exactly one jump each (no duplicates), and a netns LAN client still egressed through
  the tunnel (MASQUERADE → `tailscale0`) with **zero** packets out the local WAN.

### Boot-time sealing

On a WAN that comes up *slowly* — typically WISP/repeater, where the radio must associate to the
upstream AP — there is a brief window early in boot where lockdown is active but no WAN device
exists yet. During that window the kill-switch REJECT is **deferred, not silently skipped**: the
include logs a `WARNING: no WAN device resolved` and seals nothing, which is safe because with no
WAN egress device there is no path for client traffic to leak out. The moment the WAN associates,
its `ifup` fires the hotplug hook, which reloads the firewall and seals the kill switch (v4+v6).

In practice this means: **the kill switch is sealed by the time the WAN can actually carry traffic
to the internet** — clients cannot reach an unsealed WAN, because an unsealed WAN is one that is
not yet connected. On the test unit the seal landed ~2.5 min after power-on, right after `apcli0`
associated. A wired WAN (`eth0`), which is present at boot, is sealed in the first firewall run
with no deferral.

Other GL.iNet `fw3`/iptables devices are likely compatible but untested — please verify before
relying on the kill switch. Reports of other working (or broken) devices/firmware are welcome via
an issue or PR.

## Install

```sh
scp -O scripts/firewall.ts-lockdown.sh root@192.168.8.1:/etc/firewall.ts-lockdown.sh
scp -O scripts/ts-lockdown-hotplug.sh  root@192.168.8.1:/tmp/
scp -O scripts/ts-lockdown-status.sh   root@192.168.8.1:/tmp/
scp -O scripts/ts-lockdown-install.sh  root@192.168.8.1:/tmp/
ssh root@192.168.8.1 'chmod +x /etc/firewall.ts-lockdown.sh; sh /tmp/ts-lockdown-install.sh; /etc/init.d/firewall reload'
```

## Usage

Day to day you just pick an exit node — the lockdown applies itself. Switching nodes or toggling
Tailscale re-applies masquerade, kill switch, and DNS routing automatically; there is no manual
LuCI step, ever.

**From the GL.iNet UI:** open *Tailscale*, enable it, and choose your home node under *Exit Node*.

**From the command line (equivalent):**

```sh
# 1. List exit nodes available on your tailnet
ssh root@192.168.8.1 'tailscale exit-node list'

# 2. Select one as the permanent exit node (use your node's 100.x.y.z IP)
ssh root@192.168.8.1 '
  uci set tailscale.settings.enabled=1
  uci set tailscale.settings.exit_node_ip=100.x.y.z
  uci commit tailscale
  /usr/bin/gl_tailscale restart'

# 3. Confirm the lockdown engaged
ssh root@192.168.8.1 'cat /tmp/ts-lockdown.state'      # -> lockdown
```

Now every LAN client egresses via that exit node's public IP, and if the tunnel drops they are
blocked rather than leaking out the local WAN.

**Turn it off** (back to normal local routing):

```sh
ssh root@192.168.8.1 '
  uci set tailscale.settings.exit_node_ip=""
  uci commit tailscale
  /usr/bin/gl_tailscale restart'
# /tmp/ts-lockdown.state -> normal; all lockdown rules are removed automatically
```

## Verify

**Quick health check** — the installer adds `ts-lockdown-status` to the router:

```sh
ssh root@192.168.8.1 'ts-lockdown-status'        # human-readable report + verdict
ssh root@192.168.8.1 'ts-lockdown-status --check; echo $?'   # 0 = healthy, 1 = drift
```

It reports desired vs actual state, the derived WAN device(s), per-device seal status (v4+v6),
jump counts, whether the cron backstop is installed, and a final `healthy` / `DRIFT` verdict. The
cron backstop runs `--check` every 2 minutes and reconciles only on drift.

**Egress/DNS test** — `scripts/ts-testclient.sh` creates a throwaway network-namespace LAN client
on the router so you can test egress/DNS over SSH without a second physical device:

```sh
scp -O scripts/ts-testclient.sh root@192.168.8.1:/tmp/
ssh root@192.168.8.1 '/tmp/ts-testclient.sh up; /tmp/ts-testclient.sh run curl -s https://ifconfig.co'
# -> should print your exit node's public IP. Then tear it down:
ssh root@192.168.8.1 '/tmp/ts-testclient.sh down'
```

To test fail-closed: stop `tailscaled` and confirm the client's traffic is blocked (not falling
back to the local WAN IP).

## Uninstall

```sh
scp -O scripts/ts-lockdown-uninstall.sh root@192.168.8.1:/tmp/
ssh root@192.168.8.1 'sh /tmp/ts-lockdown-uninstall.sh'
```

Removes the include, the script, the hotplug hook, the `ts-lockdown-status` helper, the cron
backstop line, all `sysupgrade.conf` entries, and every chain/route/state, then restarts `dnsmasq`
+ the firewall — returning to stock GL behavior. Any unrelated cron entries you have are preserved.

## Configuration

The script's behavior is controlled by variables at the top of
`scripts/firewall.ts-lockdown.sh`. The main one:

- **`DNS_SERVERS`** (default `"1.1.1.1 8.8.8.8"`) — the upstream resolvers `dnsmasq` forwards to
  in lockdown. They are routed through the exit node so DNS doesn't leak to the local WAN. To use
  your own resolver, set this to its IP. A tailnet/`100.x` resolver works too and is reachable
  through the tunnel directly (no extra route needed); a public IP gets a host route via
  `tailscale0` automatically.

After editing, redeploy the script and reload: `scp -O ...` then `/etc/init.d/firewall reload`.

## Limitations

- **IPv6** forwarded egress is *blocked* (REJECTed) in lockdown, not tunneled — this prevents v6
  leaks but means LAN clients have no IPv6 internet while locked down.
- **`fw4`/nftables is untested.** The script uses iptables/`ip6tables` and targets `fw3`. Newer
  GL.iNet firmware may migrate to nftables; on such firmware this will need porting. This is the
  most likely incompatibility on other devices.
- **Multi-WAN is handled by design but only single-active-WAN is tested.** The kill switch seals
  *every* WAN device it derives (all of `wan`/`wwan`/`tethering`/`secondwan` plus every current
  default-route device), and the hotplug hook re-seals on failover or when a new WAN appears.
  Validated single-active-WAN, both wired (`eth0`) and WISP/repeater (`apcli0`). Concurrent
  load-balancing across multiple live WANs is not exercised — verify on your topology.
- The exit-node IP is read from GL's `tailscale.settings.exit_node_ip` (UCI), so it follows
  whatever you pick in the GL.iNet UI; this project does not manage exit-node *selection*.

## Security notes

- The kill switch only touches the **FORWARD** path to the WAN — the router's own management plane
  (SSH/LuCI on the LAN, which is INPUT) is never blocked, and the Tailscale underlay (OUTPUT) is
  unaffected.
- IPv6 forwarded egress is REJECTed in lockdown (defense-in-depth); if you rely on client IPv6,
  review this.
- DNS is forced to public resolvers routed through the tunnel. If you prefer your own resolver,
  edit `DNS_SERVERS` in the script (a tailnet/`100.x` resolver is reachable through the tunnel
  directly).

## Disclaimer

Provided as-is, without warranty. This is a standard self-hosted VPN/exit-node routing setup;
**you are responsible for using it in compliance with the policies and laws that apply to you and
your network.** Test thoroughly before depending on the kill switch.

## License

[MIT](LICENSE).

---

Built with [Claude Code](https://claude.com/claude-code).
