# Tailscale Exit-Node Lockdown for GL-MT3000 — Design

**Date:** 2026-06-19
**Device:** GL.iNet GL-MT3000 (Beryl AX), firmware 4.8.1, OpenWrt (kernel 5.4.211), **fw3/iptables**
**Author:** sachmata

## Goal

Make the router **always** egress to the internet via a chosen home Tailscale exit node, so that
any service sees a single, stable home public IP — reliably, automatically, and without manual
steps — regardless of where the router is physically connected. Useful for privacy, for keeping
access to services that key on a stable IP, and for a consistent egress identity while travelling.

Concretely:
- LAN client traffic is forwarded through the Tailscale tunnel to the home exit node with no
  manual masquerade step, on every enable and every exit-node switch.
- **Fail-closed:** if the home exit node is unreachable, client internet is **blocked** rather
  than falling back to the local WAN. The real location must never leak, even briefly.
- **No DNS leak:** name resolution goes through the tunnel, not the local upstream resolver.
- **No IPv6 leak:** client IPv6 cannot escape over the local WAN.
- Survives reboots, exit-node toggles, and (via `sysupgrade.conf`) firmware updates.

## Background: how GL.iNet implements Tailscale

Pulled and analysed from the live router (see `router-config/`):

- `/usr/bin/gl_tailscale` — the orchestrator. On `restart` it sets up policy routing
  (route table `52`, fwmark `0x80000`) so the router's own WAN/LAN subnets bypass the tunnel,
  runs `tailscale up --reset --accept-routes --exit-node-allow-lan-access
  --exit-node=<ip> --accept-dns=false`, then calls `/etc/firewall.tailscale.sh`.
- `/etc/firewall.tailscale.sh` — creates the `tailscale0` firewall zone and the lan↔tailscale
  / wan↔tailscale forwarding rules, then runs `/etc/init.d/firewall reload`.
- `/etc/init.d/tailscale` — procd service for `tailscaled` (`TS_DEBUG_FIREWALL_MODE=auto`).
- Hotplug `19-tailscale-iface` / `19-tailscale-net` — re-trigger `gl_tailscale` on interface events.

### Root cause of the manual-masquerade problem

`firewall.tailscale.sh::add_zone()` creates the `tailscale0` zone **without `masq=1`**:

```sh
uci set firewall.tailscale0=zone
uci set firewall.tailscale0.name=tailscale0
uci set firewall.tailscale0.input=ACCEPT
uci set firewall.tailscale0.mtu_fix='1'
uci add_list firewall.tailscale0.device=tailscale0
# ← missing: uci set firewall.tailscale0.masq='1'
```

Without masquerade, forwarded LAN traffic (192.168.8.x) enters the tunnel with its private
source IP and the exit node cannot return it. Enabling Masquerading in LuCI adds `masq=1` and
fixes it — but when Tailscale is disabled or the exit node is switched, GL's `del_rule` deletes
the entire `tailscale0` zone, and `add_zone()` recreates it without masq on the next enable.
That is why the manual fix must be repeated every time.

### Confirmed runtime facts (2026-06-19)

- **WAN:** `eth0`, proto `dhcp`; the router is itself behind an upstream NAT at `10.0.0.1`
  (travel-router scenario). Default v4 route via `eth0`.
- **IPv6:** no global address on `wan6`, no default v6 route, LAN `ra` and `dhcpv6` both
  `disabled`. No active v6 leak today; the v6 block is therefore defensive/future-proofing.
- **DNS:** dnsmasq forwards to upstream `10.0.0.1` (from `resolv.conf.auto`). The router's *own*
  DNS egress uses the OUTPUT path, which a FORWARD-only kill switch does **not** cover — so DNS
  needs explicit redirection through the tunnel.
- `lan_drop_leaked_dns` (firewall) already forces LAN clients to use the router's dnsmasq.

## Chosen approach (Approach B): independent reconciling firewall include

Leave all GL vendor files untouched. Add one script registered as a firewall include. Because GL
runs `/etc/init.d/firewall reload` at the end of every Tailscale toggle, the include fires
automatically right after GL rebuilds the zone. It reconciles to a desired state and is
idempotent, so a toggle can never leave the system half-configured.

Rejected alternatives:
- **A — patch vendor scripts in place:** wiped by firmware updates; risks breaking GL UI behavior.
- **C — standalone procd watcher daemon:** unnecessary complexity; the firewall-reload hook is
  already the exact trigger we need.

## Components

### 1. `/etc/firewall.ts-lockdown.sh` (new)
The reconciling script. Reads `tailscale.settings`. Determines desired state:

- **LOCKDOWN** when `tailscale.settings.enabled = 1` **and** `tailscale.settings.exit_node_ip`
  is non-empty.
- **NORMAL** otherwise.

Actions in **LOCKDOWN**:
1. **Masquerade** — the sole, authoritative mechanism is an owned `nat`/`POSTROUTING` rule
   `MASQUERADE` for output device `tailscale0`, placed in an owned chain (flushed/rebuilt each
   run, same as the kill switch) so it is effective immediately within the current reload and
   never accumulates duplicates. The include deliberately performs **no `uci` firewall writes**:
   a `uci commit firewall` + reload from within a firewall-reload include would cause a
   reload-within-reload loop. Correctness therefore does not depend on GL's zone or its `masq`
   setting at all.
2. **Kill switch (v4)** — in an owned iptables chain `ts_lockdown` (flushed and rebuilt each run),
   `REJECT` forwarded client traffic whose output device is **any derived WAN device** (see
   *Runtime WAN derivation* below — one REJECT per device). The router's own tunnel underlay uses
   the OUTPUT chain and is unaffected; clients can only egress via `tailscale0`. Tunnel down → no
   route → blocked (fail-closed).
3. **Kill switch (v6)** — equivalent `REJECT` in `ip6tables` for forwarded v6 out each derived WAN
   device (defensive; v6 currently inactive).
4. **DNS via tunnel** — managed dnsmasq drop-in (`no-resolv` + `server=1.1.1.1` +
   `server=8.8.8.8`), plus host routes `ip route add 1.1.1.1/8.8.8.8 dev tailscale0` added in
   `fw_build`. The router's own dnsmasq upstream queries otherwise default out the local WAN
   (table 52 is empty and the exit-node path only catches *forwarded* client traffic, not
   router-originated traffic), so the host routes are required to push those queries through the
   exit node — only then does DNS both resolve and avoid the local-WAN leak. dnsmasq is reloaded
   **only on a real state transition**.

   *Correction to original design:* MagicDNS (`100.100.100.100`) was assumed to resolve external
   names through the exit node; it does not on this tailnet (no upstream resolver configured and
   the node runs `--accept-dns=false`, so external names SERVFAIL). Forwarding to public resolvers
   routed through the tunnel is the self-contained replacement — no admin-console change, no
   vendor-file edits.

Actions in **NORMAL**:
- Remove the `ts_lockdown` chain (v4 + v6).
- Remove the DNS drop-in and restore normal resolution.
- Leave GL's own zone/masq handling alone.

Design properties:
- **Idempotent:** owned chains are flushed/rebuilt each run; teardown loop-deletes *all*
  duplicate jumps (a single `-D` plus `-X`-fails-when-referenced cannot converge duplicates),
  so no rule accumulation across reloads.
- **Concurrency-safe:** boot triggers several overlapping firewall reloads (WISP `wwan` ifup +
  Tailscale hotplug + boot firewall), invoking this script concurrently. Without protection,
  colliding `iptables` calls fail on the kernel xtables lock — leaving empty chains (masquerade
  and kill switch silently absent) and duplicate jumps, which then persist until the next reload.
  Two guards prevent this: every `iptables`/`ip6tables` call uses `-w` (wait for the xtables lock
  rather than fail — needed even with the lock below, since fw3 runs its own `iptables`
  concurrently during the reload that invokes us), and the whole reconcile is serialized with
  `flock` so instances run one at a time. *Validated by a 12-way concurrent storm (converges to
  exactly one of each rule) and by an actual reboot (lockdown re-establishes with no manual step).*
- **Transition-gated DNS:** a state marker at `/tmp/ts-lockdown.state` ensures dnsmasq is only
  bounced when the state actually changes, avoiding churn on routine firewall reloads.
- **Runtime WAN derivation (multi-WAN):** the kill-switch WAN devices are derived on every run, not
  hardcoded. Two passes: (a) the `l3_device` of each named interface `wan`/`wwan`/`tethering`/
  `secondwan` via `ubus`, then (b) every device carrying a default route (`ip route show default`),
  deduped, with `tailscale0` always excluded. `fw_build` emits one `REJECT` per derived device
  (v4 + v6), so *all* active WANs are sealed, not just one — validated across a mode change from
  wired WAN (`eth0`) to WISP/repeater (`apcli0`). Pass (b) catches WANs whose interface name is
  outside the named set (e.g. a load-balanced `wan2`) as long as they currently hold a default
  route. The remaining gap — a hot-standby WAN that is *up* but not yet the default route, and so
  invisible to both passes until it wins failover — is closed by the hotplug hook below.
- **No lock-out risk:** only the FORWARD→WAN path is touched. Management traffic
  (LAN→router = INPUT, including SSH/LuCI) is never blocked.

### 2. Firewall include registration (`/etc/config/firewall`)
A new `config include` entry of `type 'script'`, `path '/etc/firewall.ts-lockdown.sh'`,
`reload '1'`, so the script runs on every firewall reload. This UCI change lives in
`/etc/config/firewall`, which GL preserves across updates.

### 3. WAN-bringup hotplug hook (`/etc/hotplug.d/iface/99-ts-lockdown`, new)
The firewall include only reconciles when something triggers a firewall reload (boot, Tailscale
toggle, WAN mode change). A WAN that becomes active *without* a reload would stay unsealed — a
fail-open window. The most important case is **failover**: a hot-standby WAN winning the default
route is invisible to the include's runtime derivation until the next reload.

The hook reacts to netfilter `iface` hotplug events: on `ifup`/`ifupdate` of any interface that
is not `loopback`/`lan*`/`tailscale0`, it runs `/etc/init.d/firewall reload`, which re-fires the
include and re-derives + re-seals every active WAN device. The reconcile is idempotent and
`flock`-serialised, so the extra reloads are harmless; a firewall reload does not itself raise
`iface` events, so there is no feedback loop. This makes the kill switch converge on failover and
on newly-plugged WANs, not just on the existing reload triggers.

### 4. Firmware-update persistence (`/etc/sysupgrade.conf`)
Add `/etc/firewall.ts-lockdown.sh` **and** `/etc/hotplug.d/iface/99-ts-lockdown` to
`/etc/sysupgrade.conf` so both files are retained through GL firmware upgrades. (The include
entry is already preserved via `/etc/config/firewall`.)

## Data flow

```
UI toggle / exit-node switch
  → gl_tailscale restart
    → policy routing + tailscale up --exit-node=<ip>
    → firewall.tailscale.sh recreates tailscale0 zone (no masq)
      → /etc/init.d/firewall reload
        → /etc/firewall.ts-lockdown.sh  (reconcile: masq + kill switch + DNS)
```

## Failure handling

- **Exit node unreachable:** client traffic can only use `tailscale0`; with no route it is
  dropped, and the FORWARD→WAN REJECT (one per derived WAN device) prevents any local-WAN
  fallback. Fail-closed.
- **Script error during reload:** the owned chain is flushed first; a partial run leaves at worst
  the safe REJECT in place (fail-closed), never an open leak.
- **dnsmasq drop-in present but exit node down:** DNS to `1.1.1.1`/`8.8.8.8` fails (tunnel down) —
  consistent with the kill switch; no fallback to `10.0.0.1`.

## Testing strategy

1. **Baseline:** exit node off → normal internet; LAN client shows real/local public IP.
2. **Lockdown happy path:** enable exit node → LAN client `curl ifconfig.co` shows **home** IP;
   DNS resolves; **no** manual LuCI masq step required.
3. **Kill-switch:** with exit node on, stop `tailscaled` (or take the home node offline) →
   client internet **blocks**; verify no egress via `10.0.0.x` and no real-IP leak.
4. **Toggle:** switch exit node off→on→off several times → masq + kill switch re-apply
   automatically each cycle; confirm via `iptables -S` and `uci show firewall.tailscale0`.
5. **Reboot:** reboot router → lockdown re-establishes without intervention.
6. **DNS leak:** while locked down, confirm DNS queries do not reach `10.0.0.1`
   (e.g. tcpdump on `eth0` port 53 shows nothing; queries traverse the tunnel).

## Rollback

Single teardown: remove the firewall include entry, delete `/etc/firewall.ts-lockdown.sh`, remove
its `sysupgrade.conf` line, drop the DNS drop-in, and `firewall reload`. Returns to stock GL
behavior; the manual LuCI masq trick remains available as a fallback.

## Out of scope

- Multi-WAN load-balancing across multiple *simultaneously live* WANs — handled by design (every
  derived WAN device is sealed; the hotplug hook re-seals on failover) but **untested**. Only
  single-active-WAN is validated (wired `eth0` and WISP/repeater `apcli0`).
- Selective per-client routing (all LAN clients are locked down uniformly).
- Changes to GL's MagicDNS suffix handling beyond the upstream redirection above.
