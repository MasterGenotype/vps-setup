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

## Layout

```
bootstrap.sh
scripts/
  setup-wireguard.sh
  setup-dnscrypt.sh
  harden.sh
  setup-suricata.sh
  add-client.sh
  remove-client.sh
  list-clients.sh
```

DNSCrypt state is stored under:

```
/etc/dnscrypt-proxy/
/var/lib/dnscrypt-proxy/
```

The remaining WireGuard, Suricata, and device-management workflow remains
unchanged.
