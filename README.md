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
3. **`scripts/add-client.sh computer`** and **`... phone`** — creates two
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

Example — run on port 443 with Quad9 DNS:

```bash
sudo WG_PORT=443 WG_DNS=9.9.9.9,149.112.112.112 ./scripts/setup-wireguard.sh
```

> Tip: if you're on a network that blocks unknown UDP ports, `WG_PORT=443`
> often gets through.

## Optional: remote desktop (VNC)

`scripts/setup-vnc.sh` installs a lightweight XFCE desktop with TigerVNC so
you can use a graphical desktop on the VPS from your phone or computer:

```bash
sudo ./scripts/setup-vnc.sh
```

You'll be prompted to choose a VNC password. VNC is never exposed to the
open Internet — pick an access mode:

- **`VNC_ACCESS=vpn`** (default): the firewall only admits the WireGuard
  subnet. Turn the VPN on, install a VNC viewer app (e.g.
  [AVNC](https://f-droid.org/packages/gaurav.avnc/) on Android, or RealVNC
  Viewer), and connect to `10.8.0.1:5901`.
- **`VNC_ACCESS=ssh`**: listens on localhost only; connect through an SSH
  tunnel. From Termux on Android:

  ```bash
  pkg install openssh
  ssh -L 5901:127.0.0.1:5901 <user>@YOUR_SERVER_IP
  ```

  Keep that running and point the VNC viewer app at `127.0.0.1:5901`.
  (Termux only carries the tunnel — the desktop is displayed by the viewer
  app.)

Options: `VNC_USER` (desktop account, never root), `VNC_DISPLAY` (default
`1` → port 5901), `VNC_GEOMETRY` (default `1280x720`), `VNC_DEPTH`,
`VNC_PASSWORD` (skip the prompt). Manage with
`sudo systemctl {status|restart|stop} vncserver@1`.

## Layout

```
bootstrap.sh                 # one-shot: setup + hardening + initial clients
scripts/
  setup-wireguard.sh         # WireGuard server install & configuration
  harden.sh                  # unattended-upgrades, fail2ban, SSH lockdown
  add-client.sh              # add a device (config + QR code)
  remove-client.sh           # revoke a device
  list-clients.sh            # status / re-print QR codes
  setup-vnc.sh               # optional XFCE remote desktop over VPN/SSH
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
