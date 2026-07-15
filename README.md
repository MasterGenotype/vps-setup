# vps-setup

Automated setup of an Ubuntu VPS as an encrypted **WireGuard VPN tunnel** with optional DNSCrypt-Proxy encrypted DNS.

## Quick start

```bash
git clone https://github.com/MasterGenotype/vps-setup.git
cd vps-setup
sudo ./bootstrap.sh
```

The pipeline installs WireGuard, optional DNSCrypt-Proxy, hardening, Suricata, and initial client profiles.

## DNSCrypt-Proxy

DNSCrypt-Proxy is installed after WireGuard setup and before client generation. It listens only on WireGuard tunnel addresses and is never exposed on the VPS public interface.

Skip it with:

```bash
sudo NO_DNSCRYPT=1 ./bootstrap.sh
```

Configuration variables:

| Variable | Purpose |
| --- | --- |
| `DNSCRYPT_VERSION` | Pinned upstream DNSCrypt-Proxy release |
| `DNSCRYPT_SERVER_NAMES` | Optional explicit resolver names |
| `DNSCRYPT_IPV6_UPSTREAM` | Enable IPv6 upstream resolvers |
| `DNSCRYPT_REQUIRE_DNSSEC` | Require DNSSEC support |
| `DNSCRYPT_REQUIRE_NOLOG` | Require no logging policy |
| `DNSCRYPT_REQUIRE_NOFILTER` | Require no filtering policy |

DNS is pushed to WireGuard clients as the tunnel resolver address. Existing
client configuration files are updated automatically; already imported devices
must re-import the updated configuration.

## Artix ISO chroot

`setup-artix-chroot.sh` creates a reusable Artix Linux chroot from the files
included in the weekly base-runit installation ISO. It does not assume a fixed
internal ISO path: it mounts the ISO read-only, scans filesystem-image
candidates, validates candidates by looking for a usable Linux root tree, and
supports one nested filesystem-image layer.

The default source is:

```text
https://download.artixlinux.org/weekly-iso/artix-base-runit-20260626-x86_64.iso
```

Create a chroot at a user-selected absolute path:

```bash
sudo ./scripts/setup-artix-chroot.sh /srv/chroots/artix
```

The script:

1. Downloads or reuses the cached ISO under `/var/cache/vps-setup/artix/`.
2. Verifies it with the SHA256 published on the Artix downloads page, falling
   back to the detached Artix PGP signature when necessary.
3. Mounts the ISO and detects the actual root filesystem image.
4. Copies the root tree while preserving numeric ownership, hard links, ACLs,
   extended attributes, devices, and special files.
5. Prepares DNS and mounts `/dev`, `/proc`, `/sys`, and `/run` for chroot use.

Enter or unmount the prepared environment:

```bash
sudo ./scripts/setup-artix-chroot.sh --enter /srv/chroots/artix
sudo ./scripts/setup-artix-chroot.sh --unmount /srv/chroots/artix
```

Useful options:

```bash
# Force a clean ISO download.
sudo ./scripts/setup-artix-chroot.sh --refresh /srv/chroots/artix

# Replace an existing non-empty target.
sudo ./scripts/setup-artix-chroot.sh --force /srv/chroots/artix

# Use a different Artix ISO or cache directory.
sudo ./scripts/setup-artix-chroot.sh \
  --iso-url https://example.invalid/artix-base-runit.iso \
  --cache-dir /srv/iso-cache \
  /srv/chroots/artix
```

The target must be an absolute path. The script refuses `/`, `/dev`, `/proc`,
`/sys`, `/run`, and paths below those locations.

## Layout

```text
bootstrap.sh
scripts/
  setup-wireguard.sh
  setup-dnscrypt.sh
  setup-artix-chroot.sh
  harden.sh
  setup-suricata.sh
  add-client.sh
  remove-client.sh
  list-clients.sh
```

DNSCrypt state is stored under:

```text
/etc/dnscrypt-proxy/
/var/lib/dnscrypt-proxy/
```

The remaining WireGuard, Suricata, and device-management workflow remains
unchanged.
