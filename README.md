# vps-setup

Automated setup of an Ubuntu VPS as an **encrypted tunnel (WireGuard VPN)**
between your computer/phone and the Internet. All device traffic is routed
through the VPS over WireGuard and NAT'd out, hiding it from local networks
and your ISP.

## Requirements

- A VPS running Ubuntu 20.04 or newer, with a public IPv4 address
- Root (or sudo) access on the VPS
- The [WireGuard app](https://www.wireguard.com/install/) on your devices

## Quick start

On the VPS:

```bash
git clone https://github.com/MasterGenotype/vps-setup.git
cd vps-setup
sudo ./bootstrap.sh
```

This runs the full pipeline:

1. **`scripts/setup-wireguard.sh`** — installs WireGuard, generates server
   keys, writes `wg0.conf` with NAT rules, enables IP forwarding, opens the
   firewall (UFW: SSH + WireGuard UDP), and starts the service.
2. **`scripts/harden.sh`** — enables automatic security updates, installs
   fail2ban for SSH, and (only if an SSH key is already installed) disables
   password login.
3. **`scripts/setup-suricata.sh`** — installs [Suricata](https://suricata.io/)
   as an intrusion detection & prevention system (IDPS) inspecting traffic
   inline, with the free ET Open ruleset refreshed daily. Skip with
   `NO_SURICATA=1`, or run detect-only with `SURICATA_MODE=ids`.
4. **`scripts/setup-dnscrypt.sh`** — installs
   [dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy) so the
   server and all VPN devices resolve DNS through encrypted, no-log
   resolvers instead of plaintext port 53. Skip with `NO_DNSCRYPT=1`.
5. **`scripts/add-client.sh computer`** and **`... phone`** — creates two
   initial device configs. The phone's QR code is printed to the terminal.

### Connect your phone

Open the WireGuard app → **+** → **Create from QR code** → scan the code
printed during setup. Re-print it anytime:

```bash
sudo ./scripts/list-clients.sh --qr phone
```

### Connect your computer

Copy the config off the server, then import it:

```bash
scp root@YOUR_SERVER_IP:/etc/wireguard/clients/computer/computer.conf .
```

- **macOS / Windows**: import the file in the WireGuard app.
- **Linux**:
  ```bash
  sudo cp computer.conf /etc/wireguard/
  sudo wg-quick up computer
  ```

Verify the tunnel is active: visit <https://ifconfig.me> — it should show
your VPS's IP.

## Managing devices

```bash
sudo ./scripts/add-client.sh tablet         # add a device (prints QR code)
sudo ./scripts/add-client.sh work --split   # split tunnel: only VPN subnet routed
sudo ./scripts/list-clients.sh              # devices + last handshake times
sudo ./scripts/remove-client.sh tablet      # revoke a device immediately
```

## Encrypted DNS (dnscrypt-proxy)

`setup-dnscrypt.sh` runs dnscrypt-proxy on the server, listening on
loopback and on the WireGuard tunnel IPs (e.g. `10.8.0.1`). Upstream
resolution uses DNSCrypt/DNS-over-HTTPS to no-log resolvers, picked
automatically by latency — or pin your own:

```bash
sudo DNSCRYPT_SERVERS=quad9-dnscrypt-ip4-filter-pri ./scripts/setup-dnscrypt.sh
```

How it fits the tunnel: client configs get `DNS = 10.8.0.1` (the server's
tunnel address), so every lookup travels inside WireGuard to the VPS and
leaves it encrypted — your DNS is hidden from local networks, your ISP,
and the VPS's network too. The script updates the persisted `WG_DNS` (new
clients pick it up automatically) and rewrites existing client configs —
**already-connected devices must re-import their config** (`list-clients.sh
--qr <name>` for phones, re-copy the `.conf` for computers).

The server's own lookups go through the proxy as well (via
systemd-resolved), but only after the script has verified the proxy
answers a live query — a failed install can't break the host's DNS. Port
53 is opened on the WireGuard interface only, never publicly.

## Intrusion detection / prevention (Suricata)

`setup-suricata.sh` runs Suricata in **IDPS mode** by default: traffic is
inspected inline, every rule alerts, and a conservative set of
high-confidence categories (trojan-activity, exploit-kit,
command-and-control) is actively blocked. `HOME_NET` is set automatically
to the server's public IP plus the WireGuard tunnel subnets. Rules (the
free ET Open ruleset) are fetched at setup and refreshed daily by a systemd
timer (`suricata-update.timer`).

```bash
sudo ./scripts/suricata-alerts.sh            # last 20 alerts, one per line
sudo ./scripts/suricata-alerts.sh 100        # last 100
sudo ./scripts/suricata-alerts.sh --follow   # live stream
```

Raw logs live in `/var/log/suricata/` (`fast.log` for humans, `eve.json`
for tooling), rotated daily and kept for a week.

### Modes

Re-run the script with a different mode to switch (the choice persists,
and switching to `ids` cleans up after the inline modes):

```bash
sudo SURICATA_MODE=idps ./scripts/setup-suricata.sh   # default: detect + block defaults
sudo SURICATA_MODE=ips  ./scripts/setup-suricata.sh   # detect + block only what you pick
sudo SURICATA_MODE=ids  ./scripts/setup-suricata.sh   # detect-only, nothing inline
```

| Mode   | Inline? | Blocks out of the box                                   |
| ------ | ------- | ------------------------------------------------------- |
| `idps` | yes     | trojan-activity, exploit-kit, command-and-control rules |
| `ips`  | yes     | nothing until you enable entries in `drop.conf`          |
| `ids`  | no      | nothing — detection only                                 |

In both inline modes traffic is diverted through Suricata via NFQUEUE with
two safety nets:

- **Fail-open** — if Suricata stops, traffic flows normally instead of
  dropping (`--queue-bypass`).
- **SSH exempt** — your SSH port is never queued, so a rule false-positive
  can't lock you out. UFW and fail2ban still apply to all traffic.

Inline, only rules whose action is `drop` actually block traffic; the rest
keep alerting (that's the "detection" half). What gets dropped is
controlled by `/etc/suricata/drop.conf`: one pattern per line — a signature
ID, `gid:sid`, or `re:<regex>`. `ips` installs it fully commented so you
promote signatures yourself; `idps` activates the three conservative
high-confidence categories above and leaves the rest of the file alone.
After editing, apply with:

```bash
sudo systemctl start suricata-update.service
```

> Note: Suricata with the full ET Open ruleset is happiest with **2 GB+
> RAM**. On a small VPS, skip it at bootstrap with `NO_SURICATA=1`.

## Configuration

Every setting has a sensible default and can be overridden via environment
variables when running `setup-wireguard.sh` (choices persist in
`/etc/wireguard/vps-setup.env` and are reused by the other scripts):

| Variable      | Default           | Purpose                              |
| ------------- | ----------------- | ------------------------------------ |
| `WG_PORT`     | `51820`           | UDP listen port                      |
| `WG_IPV4_NET` | `10.8.0.0/24`     | Tunnel IPv4 subnet                   |
| `WG_IPV6_NET` | `fd42:8:8::/64`   | Tunnel IPv6 subnet                   |
| `WG_DNS`      | `1.1.1.1,1.0.0.1` | DNS servers pushed to clients        |
| `WG_ENDPOINT` | auto-detected     | Public address clients connect to    |
| `WAN_IF`      | auto-detected     | Outbound network interface for NAT   |

And for `setup-suricata.sh`:

| Variable            | Default        | Purpose                              |
| ------------------- | -------------- | ------------------------------------ |
| `SURICATA_MODE`     | `idps`         | `idps`, `ips` or `ids` (see below)   |
| `SURICATA_IFACE`    | WAN interface  | Interface to monitor (e.g. `wg0`)    |
| `SURICATA_HOME_NET` | auto-detected  | Suricata `HOME_NET` override         |

And for `setup-dnscrypt.sh`:

| Variable           | Default   | Purpose                                     |
| ------------------ | --------- | ------------------------------------------- |
| `DNSCRYPT_SERVERS` | automatic | Pin specific resolvers (comma-separated names from the [public list](https://dnscrypt.info/public-servers)) |

Example — run on port 443 with Quad9 DNS:

```bash
sudo WG_PORT=443 WG_DNS=9.9.9.9,149.112.112.112 ./scripts/setup-wireguard.sh
```

> Tip: if you're on a network that blocks unknown UDP ports, `WG_PORT=443`
> often gets through.

## Layout

```
bootstrap.sh                 # one-shot: setup + hardening + IDS + initial clients
scripts/
  setup-wireguard.sh         # WireGuard server install & configuration
  harden.sh                  # unattended-upgrades, fail2ban, SSH lockdown
  setup-suricata.sh          # Suricata IDS/IPS install & configuration
  suricata-alerts.sh         # readable view of recent/live IDS alerts
  setup-dnscrypt.sh          # encrypted DNS (dnscrypt-proxy) for host + VPN
  add-client.sh              # add a device (config + QR code)
  remove-client.sh           # revoke a device
  list-clients.sh            # status / re-print QR codes
  lib/common.sh              # shared helpers
```

Server state lives in `/etc/wireguard/`: `wg0.conf` (server + peers),
`server.key`/`server.pub`, `clients/<name>/<name>.conf`, and
`vps-setup.env` (persisted settings). All scripts are idempotent — re-running
them is safe.

## Security notes

- Each client gets its own keypair **and** a preshared key (extra
  post-quantum-resistant layer on top of WireGuard's Curve25519).
- Client private keys are generated on the server for convenience; for
  maximum security, generate keys on the device and add only the public key
  to `wg0.conf` manually.
- `remove-client.sh` revokes access immediately via `wg syncconf` — no
  restart, no disruption to other devices.
- The firewall only exposes SSH and the WireGuard port.
- Suricata inspects traffic inline for known-bad patterns (ET Open ruleset,
  auto-updated daily) and blocks high-confidence malware/C2/exploit-kit
  traffic by default. Blocking is designed to fail open — SSH is never
  filtered and traffic flows normally if Suricata stops — so it can never
  cut you off. Detect-only: `SURICATA_MODE=ids`.
- DNS queries never leave the VPS in plaintext: devices resolve through the
  tunnel to dnscrypt-proxy, which speaks DNSCrypt/DoH to no-log resolvers.
