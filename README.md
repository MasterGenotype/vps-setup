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

By default the script constructs the download URL itself: it fetches the
`sha256sums` manifest from the weekly ISO directory, picks the newest
`artix-base-runit-YYYYMMDD-x86_64.iso` entry, and uses the checksum published
alongside it, so every run pulls the current weekly image:

```text
https://download.artixlinux.org/weekly-iso/
```

If the manifest is unreachable it falls back to scraping the directory index
for the newest ISO filename. `--iso-url` (or `ARTIX_ISO_URL`) pins a specific
image instead, and `ARTIX_ISO_VARIANT` selects a different weekly variant
(default `base-runit`).

Create a chroot at a user-selected absolute path:

```bash
sudo ./scripts/setup-artix-chroot.sh /srv/chroots/artix
```

The script:

1. Discovers the latest weekly ISO and its SHA256 from the `sha256sums`
   manifest, then downloads it or reuses the cached copy under
   `/var/cache/vps-setup/artix/`.
2. Verifies weekly images against the checksum published in the same Artix
   ISO directory. The general downloads page is used as a fallback.
3. Mounts the ISO and detects the actual root filesystem image.
4. Copies the root tree while preserving numeric ownership, hard links, ACLs,
   extended attributes, devices, and special files.
5. Disables pacman's `CheckSpace` option inside the chroot. Its free-space
   check reads mount points from `/proc/self/mounts`, which shows host mounts
   inside the chroot, so `pacman -Syu` would otherwise abort with a spurious
   "Partition too full" error.
6. Prepares DNS and mounts `/dev`, `/proc`, `/sys`, and `/run` for chroot use.

`--enter` applies the same `CheckSpace` fix to chroots created before it was
introduced.

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

# Supply a trusted published hash manually if metadata servers are unavailable.
sudo ARTIX_ISO_SHA256=<64-character-sha256> \
  ./scripts/setup-artix-chroot.sh /srv/chroots/artix
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
