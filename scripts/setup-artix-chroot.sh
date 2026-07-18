#!/usr/bin/env bash
#
# setup-artix-chroot.sh — download the latest Artix base-runit weekly ISO,
# locate the live root filesystem inside it, copy that filesystem into a
# user-selected target, and prepare the target for chroot use.
#
# By default the script discovers the newest weekly ISO and its SHA256 from
# the published manifest:
#   https://download.artixlinux.org/weekly-iso/sha256sums
# so it always pulls the current artix-base-runit x86_64 weekly image.
# Pin a specific image with --iso-url or ARTIX_ISO_URL.
#
# Usage:
#   sudo ./scripts/setup-artix-chroot.sh /srv/chroots/artix
#   sudo ./scripts/setup-artix-chroot.sh --refresh /srv/chroots/artix
#   sudo ./scripts/setup-artix-chroot.sh --iso-url URL /srv/chroots/artix
#   sudo ./scripts/setup-artix-chroot.sh --enter /srv/chroots/artix
#   sudo ./scripts/setup-artix-chroot.sh --unmount /srv/chroots/artix

set -euo pipefail

# Space-separated candidate directories that publish the weekly ISOs and a
# sha256sums manifest, tried in order until one answers.
WEEKLY_ISO_BASE_URLS="${ARTIX_WEEKLY_ISO_BASE_URL:-https://download.artixlinux.org/weekly-iso https://iso.artixlinux.org/weekly-iso}"
ISO_VARIANT="${ARTIX_ISO_VARIANT:-base-runit}"
DOWNLOAD_PAGE_URL="https://artixlinux.org/download.php"
CACHE_DIR="${ARTIX_ISO_CACHE_DIR:-/var/cache/vps-setup/artix}"
# Empty means "discover the latest weekly ISO"; set to pin a specific image.
ISO_URL="${ARTIX_ISO_URL:-}"
ISO_SHA256="${ARTIX_ISO_SHA256:-}"
ISO_SHA256_SOURCE="ARTIX_ISO_SHA256"
HTTP_USER_AGENT="${ARTIX_HTTP_USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126 Safari/537.36}"
REFRESH=0
FORCE=0
MODE="setup"
TARGET=""

WORK_DIR=""
ISO_MOUNT=""
ROOT_MOUNT=""
ROOT_SOURCE=""
ISO_PATH=""
MOUNT_POINTS=()

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage:
  setup-artix-chroot.sh [options] TARGET
  setup-artix-chroot.sh --enter TARGET [COMMAND [ARG...]]
  setup-artix-chroot.sh --unmount TARGET

Options:
  --iso-url URL     Use a specific ISO instead of the latest weekly image.
  --cache-dir DIR   Store the ISO and signature in DIR.
  --refresh         Re-download the ISO even when a cached copy exists.
  --force           Replace the contents of a non-empty TARGET.
  --enter           Enter an existing prepared chroot.
  --unmount         Unmount /run, /sys, /proc and /dev below TARGET.
  -h, --help        Show this help.

Without --iso-url the script reads the sha256sums manifest below the weekly
ISO directory, picks the newest artix-base-runit x86_64 image, and verifies
the download against the checksum published in the same manifest.

Environment overrides:
  ARTIX_ISO_URL              Pin a specific ISO URL (skips weekly discovery).
  ARTIX_WEEKLY_ISO_BASE_URL  Weekly ISO directories, space-separated, tried
                             in order (default:
                             https://download.artixlinux.org/weekly-iso
                             https://iso.artixlinux.org/weekly-iso).
  ARTIX_ISO_VARIANT          Weekly image variant (default: base-runit).
  ARTIX_ISO_CACHE_DIR
  ARTIX_ISO_SHA256
  ARTIX_HTTP_USER_AGENT
USAGE
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "This script must be run as root (try: sudo $0 ...)"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

canonicalize_target() {
    local requested="$1" parent base

    [[ -n ${requested} ]] || die "A chroot target directory is required"
    [[ ${requested} == /* ]] || die "TARGET must be an absolute path: ${requested}"

    if [[ -e ${requested} || -L ${requested} ]]; then
        TARGET="$(readlink -f -- "${requested}")" \
            || die "Unable to resolve TARGET: ${requested}"
    else
        parent="$(dirname -- "${requested}")"
        base="$(basename -- "${requested}")"
        mkdir -p -- "${parent}"
        parent="$(readlink -f -- "${parent}")"
        TARGET="${parent}/${base}"
    fi

    [[ ${TARGET} != "/" ]] || die "Refusing to use / as the chroot target"
    [[ ${TARGET} != "/proc" && ${TARGET} != /proc/* ]] || die "Refusing target below /proc"
    [[ ${TARGET} != "/sys" && ${TARGET} != /sys/* ]] || die "Refusing target below /sys"
    [[ ${TARGET} != "/dev" && ${TARGET} != /dev/* ]] || die "Refusing target below /dev"
    [[ ${TARGET} != "/run" && ${TARGET} != /run/* ]] || die "Refusing target below /run"
}

cleanup_temporary_mounts() {
    local i mountpoint
    for ((i=${#MOUNT_POINTS[@]}-1; i>=0; i--)); do
        mountpoint="${MOUNT_POINTS[i]}"
        if mountpoint -q -- "${mountpoint}"; then
            umount --lazy -- "${mountpoint}" 2>/dev/null || true
        fi
    done
    [[ -z ${WORK_DIR} ]] || rm -rf -- "${WORK_DIR}"
}
trap cleanup_temporary_mounts EXIT
trap 'die "setup-artix-chroot.sh failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

install_host_dependencies() {
    local missing=()
    local command

    for command in curl gpg mount mountpoint findmnt rsync unsquashfs sha256sum chroot; do
        command -v "${command}" >/dev/null 2>&1 || missing+=("${command}")
    done

    if (( ${#missing[@]} == 0 )); then
        return 0
    fi

    command -v apt-get >/dev/null 2>&1 \
        || die "Missing commands (${missing[*]}) and automatic installation only supports apt-get hosts"

    log "Installing host dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -yq \
        ca-certificates curl gnupg dirmngr file rsync squashfs-tools util-linux
}

# http_fetch URL OUTPUT [extra curl options...]
#
# Fetch URL into OUTPUT. Tries the configured (browser-like) User-Agent
# first; if the server answers 403, retries once with curl's native
# User-Agent — some CDN bot filters reject spoofed browser agents that lack
# the other browser headers, while others reject plain curl, so between the
# two attempts one usually passes. Every failed attempt logs the URL and the
# HTTP status so the blocked request is identifiable.
http_fetch() {
    local url="$1" output="$2"
    shift 2
    local ua_mode status curl_args

    for ua_mode in browser curl; do
        curl_args=(--proto '=https' --tlsv1.2 --fail --location --retry 3
                   --retry-delay 2 --progress-bar
                   --write-out '%{http_code}' --output "${output}")
        if [[ ${ua_mode} == browser ]]; then
            curl_args+=(--user-agent "${HTTP_USER_AGENT}")
        fi
        if status="$(curl "${curl_args[@]}" "$@" "${url}")"; then
            return 0
        fi
        warn "GET ${url} failed (HTTP ${status:-000}, ${ua_mode} user agent)"
        [[ ${status} == 403 ]] || return 1
    done
    return 1
}

download_file() {
    local url="$1" destination="$2" partial
    partial="${destination}.part"

    mkdir -p -- "$(dirname -- "${destination}")"
    if [[ -s ${partial} ]]; then
        log "Resuming partial download: ${partial}"
        http_fetch "${url}" "${partial}" --continue-at - \
            || die "Download failed: ${url}"
    else
        http_fetch "${url}" "${partial}" \
            || die "Download failed: ${url}"
    fi
    mv -f -- "${partial}" "${destination}"
}

checksum_from_url() {
    local source_url="$1" iso_name="$2" destination="$3" checksum

    http_fetch "${source_url}" "${destination}" || return 1

    checksum="$(grep -Eo "[[:xdigit:]]{64}[[:space:]]+${iso_name//./\\.}" "${destination}" \
        | awk 'NR == 1 {print tolower($1)}')"
    [[ ${checksum} =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${checksum}"
}

# Construct the URL of the current weekly ISO. The weekly directories publish
# a sha256sums manifest next to the images, so one fetch yields both the
# newest filename and its checksum. The dates are fixed-width (YYYYMMDD) and
# the rest of the filename is constant for a given variant, so a plain sort
# on the filename orders the entries chronologically.
discover_weekly_iso() {
    local name_pattern="artix-${ISO_VARIANT}-[0-9]{8}-x86_64\.iso"
    local base manifest_name manifest index entry iso_name fetch_id=0

    log "Discovering the latest ${ISO_VARIANT} weekly ISO"

    for base in ${WEEKLY_ISO_BASE_URLS}; do
        base="${base%/}"
        for manifest_name in sha256sums sha256sums.txt; do
            manifest="${WORK_DIR}/weekly-sums-$((fetch_id++))"
            http_fetch "${base}/${manifest_name}" "${manifest}" || continue
            entry="$(grep -Eo "[[:xdigit:]]{64}[[:space:]]+\*?${name_pattern}" \
                "${manifest}" | sort -k2,2 | tail -n1 || true)"
            if [[ -z ${entry} ]]; then
                warn "No artix-${ISO_VARIANT} x86_64 entries in ${base}/${manifest_name}"
                continue
            fi
            iso_name="$(awk '{print $NF}' <<<"${entry}")"
            iso_name="${iso_name#\*}"
            ISO_URL="${base}/${iso_name}"
            if [[ -z ${ISO_SHA256} ]]; then
                ISO_SHA256="$(awk '{print tolower($1)}' <<<"${entry}")"
                ISO_SHA256_SOURCE="${base}/${manifest_name}"
            fi
            log "Latest weekly ISO: ${iso_name} (from ${base}/${manifest_name})"
            return 0
        done
    done

    # No manifest was usable; fall back to scraping the directory indexes.
    # Verification then relies on verify_iso finding a published checksum.
    for base in ${WEEKLY_ISO_BASE_URLS}; do
        base="${base%/}"
        index="${WORK_DIR}/weekly-index-$((fetch_id++)).html"
        http_fetch "${base}/" "${index}" || continue
        iso_name="$(grep -Eo "${name_pattern}" "${index}" | sort -u | tail -n1 || true)"
        [[ -n ${iso_name} ]] || continue
        ISO_URL="${base}/${iso_name}"
        log "Latest weekly ISO (from directory index): ${ISO_URL}"
        return 0
    done

    die "Unable to discover the latest weekly ISO (tried: ${WEEKLY_ISO_BASE_URLS}). See the warnings above for the exact URL and HTTP status of each attempt. Pass --iso-url (or set ARTIX_ISO_URL) to pin one explicitly."
}

# Weekly images rotate out of the download directory, so an unverifiable
# weekly ISO must be treated as an error rather than falling through to the
# stable-ISO signature path.
is_weekly_source() {
    local base
    [[ ${ISO_URL} == */weekly-iso/* ]] && return 0
    for base in ${WEEKLY_ISO_BASE_URLS}; do
        if [[ ${ISO_URL} == "${base%/}"/* ]]; then
            return 0
        fi
    done
    return 1
}

verify_iso() {
    local iso_path="$1" iso_name="$2" sig_path="$3"
    local expected actual gpg_home checksum_source manifest_url

    manifest_url="${ISO_URL%/*}/sha256sums"
    checksum_source=""

    if [[ -n ${ISO_SHA256} ]]; then
        expected="${ISO_SHA256,,}"
        [[ ${expected} =~ ^[0-9a-f]{64}$ ]] \
            || die "The expected SHA256 must contain exactly 64 hexadecimal characters (source: ${ISO_SHA256_SOURCE})"
        checksum_source="${ISO_SHA256_SOURCE}"
    else
        expected="$(checksum_from_url "${manifest_url}" "${iso_name}" \
            "${WORK_DIR}/sha256sums" || true)"
        if [[ -n ${expected} ]]; then
            checksum_source="${manifest_url}"
        else
            expected="$(checksum_from_url "${DOWNLOAD_PAGE_URL}" "${iso_name}" \
                "${WORK_DIR}/artix-download.html" || true)"
            if [[ -n ${expected} ]]; then
                checksum_source="${DOWNLOAD_PAGE_URL}"
            fi
        fi
    fi

    if [[ -n ${expected} ]]; then
        actual="$(sha256sum "${iso_path}" | awk '{print $1}')"
        [[ ${actual} == "${expected}" ]] \
            || die "SHA256 mismatch for ${iso_name}: expected ${expected}, got ${actual}"
        log "Verified ${iso_name} using ${checksum_source}"
        return 0
    fi

    if is_weekly_source; then
        die "Could not obtain the weekly SHA256 for ${iso_name}. Tried ${manifest_url} and ${DOWNLOAD_PAGE_URL}. Set ARTIX_ISO_SHA256 to a trusted published checksum and re-run."
    fi

    warn "No matching SHA256 was found; trying the detached PGP signature"
    http_fetch "${ISO_URL}.sig" "${sig_path}" \
        || die "Could not obtain a checksum or detached signature for ${iso_name}"

    gpg_home="${WORK_DIR}/gnupg"
    install -d -m 0700 -- "${gpg_home}"
    if ! GNUPGHOME="${gpg_home}" gpg --batch --keyserver hkps://keyserver.ubuntu.com \
        --recv-keys 0xB886B428; then
        die "Could not retrieve the Artix ISO signing key 0xB886B428"
    fi
    GNUPGHOME="${gpg_home}" gpg --batch --verify "${sig_path}" "${iso_path}" \
        || die "PGP verification failed for ${iso_name}"
    log "Verified ${iso_name} with the Artix ISO signing key"
}

obtain_iso() {
    local iso_name iso_path sig_path

    if [[ -z ${ISO_URL} ]]; then
        discover_weekly_iso
    fi

    iso_name="${ISO_URL##*/}"
    [[ ${iso_name} == artix-${ISO_VARIANT}-*-x86_64.iso ]] \
        || warn "ISO filename is not the expected Artix ${ISO_VARIANT} x86_64 pattern: ${iso_name}"

    iso_path="${CACHE_DIR}/${iso_name}"
    sig_path="${iso_path}.sig"
    mkdir -p -- "${CACHE_DIR}"

    if (( REFRESH )); then
        rm -f -- "${iso_path}" "${iso_path}.part" "${sig_path}"
    fi

    if [[ ! -s ${iso_path} ]]; then
        log "Downloading ${ISO_URL}"
        download_file "${ISO_URL}" "${iso_path}"
    else
        log "Using cached ISO: ${iso_path}"
    fi

    verify_iso "${iso_path}" "${iso_name}" "${sig_path}"
    ISO_PATH="${iso_path}"
}

mount_readonly_image() {
    local image="$1" mount_dir="$2"

    mkdir -p -- "${mount_dir}"
    if mount -o loop,ro -- "${image}" "${mount_dir}" 2>/dev/null; then
        MOUNT_POINTS+=("${mount_dir}")
        return 0
    fi

    # A restricted VPS kernel may not expose the SquashFS module. In that case,
    # extract a SquashFS candidate into the temporary probe directory instead.
    if unsquashfs -s "${image}" >/dev/null 2>&1; then
        rm -rf -- "${mount_dir}"
        if unsquashfs -no-progress -d "${mount_dir}" "${image}" >/dev/null; then
            return 0
        fi
    fi

    return 1
}

is_root_filesystem() {
    local root="$1"

    [[ -f ${root}/etc/os-release ]] || return 1
    [[ -x ${root}/bin/sh || -x ${root}/usr/bin/sh || \
       -x ${root}/bin/bash || -x ${root}/usr/bin/bash ]] || return 1
    [[ -d ${root}/etc && -d ${root}/usr ]] || return 1
    return 0
}

candidate_priority() {
    local path="$1" name
    name="${path##*/}"
    case "${name}" in
        rootfs.sfs|rootfs.squashfs|rootfs.sqfs|airootfs.sfs|airootfs.squashfs) printf '10' ;;
        *.sfs|*.squashfs|*.sqfs|*.erofs) printf '20' ;;
        *.img) printf '30' ;;
        *) printf '99' ;;
    esac
}

find_image_candidates() {
    local root="$1"
    find "${root}" -type f \
        \( -iname '*.sfs' -o -iname '*.squashfs' -o -iname '*.sqfs' \
           -o -iname '*.erofs' -o -iname '*.img' \) \
        -printf '%p\n' 2>/dev/null \
        | while IFS= read -r candidate; do
            printf '%s\t%s\n' "$(candidate_priority "${candidate}")" "${candidate}"
          done \
        | sort -n -k1,1 -k2,2 \
        | cut -f2-
}

locate_root_filesystem() {
    local iso_root="$1" candidate probe nested nested_probe index=0 nested_index=0

    while IFS= read -r candidate; do
        [[ -n ${candidate} ]] || continue
        probe="${WORK_DIR}/probe-${index}"
        index=$((index + 1))

        if ! mount_readonly_image "${candidate}" "${probe}"; then
            continue
        fi

        if is_root_filesystem "${probe}"; then
            ROOT_SOURCE="${candidate}"
            ROOT_MOUNT="${probe}"
            return 0
        fi

        # Some live media wrap the actual filesystem image inside a SquashFS.
        while IFS= read -r nested; do
            [[ -n ${nested} ]] || continue
            nested_probe="${WORK_DIR}/nested-probe-${nested_index}"
            nested_index=$((nested_index + 1))
            if mount_readonly_image "${nested}" "${nested_probe}" \
                && is_root_filesystem "${nested_probe}"; then
                ROOT_SOURCE="${candidate} -> ${nested}"
                ROOT_MOUNT="${nested_probe}"
                return 0
            fi
        done < <(find_image_candidates "${probe}")
    done < <(find_image_candidates "${iso_root}")

    return 1
}

prepare_target_directory() {
    mkdir -p -- "${TARGET}"

    if findmnt -Rno TARGET "${TARGET}" 2>/dev/null | grep -q .; then
        die "TARGET already contains mounted filesystems; unmount it before replacing its contents"
    fi

    if find "${TARGET}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        if (( ! FORCE )); then
            die "TARGET is not empty: ${TARGET} (use --force to replace it)"
        fi
        warn "Removing existing contents from ${TARGET}"
        find "${TARGET}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
}

copy_root_filesystem() {
    log "Extracting the detected root filesystem into ${TARGET}"
    rsync -aHAX --numeric-ids --devices --specials --one-file-system \
        "${ROOT_MOUNT}/" "${TARGET}/"

    is_root_filesystem "${TARGET}" \
        || die "The extracted tree does not look like a usable Linux root filesystem"

    grep -qiE '(^|[[:space:]])artix([[:space:]]|$)' "${TARGET}/etc/os-release" \
        || warn "Extracted /etc/os-release does not clearly identify Artix Linux"
}

# pacman's CheckSpace option resolves mount points from /proc/self/mounts to
# measure free space before a transaction. Inside the chroot that table lists
# host mounts that do not match the chroot's view of the filesystem (the
# chroot root is not a mount point, and /run is a small host tmpfs), so
# `pacman -Syu` aborts with a spurious "Partition ... too full" error even
# when the target has plenty of space. Disable the check; writes still fail
# cleanly if the disk genuinely fills up.
disable_pacman_checkspace() {
    local pacman_conf="${TARGET}/etc/pacman.conf"

    if [[ ! -f ${pacman_conf} ]]; then
        warn "No pacman.conf found at ${pacman_conf}; skipping CheckSpace adjustment"
        return 0
    fi

    if grep -Eq '^[[:space:]]*CheckSpace([[:space:]]|$)' "${pacman_conf}"; then
        sed -i -E 's/^[[:space:]]*(CheckSpace)/#\1/' "${pacman_conf}"
        log "Disabled pacman CheckSpace in ${pacman_conf} (unreliable inside a chroot)"
    fi
}

prepare_resolver() {
    local source="/etc/resolv.conf"

    if [[ -r /run/systemd/resolve/resolv.conf ]]; then
        source="/run/systemd/resolve/resolv.conf"
    fi

    if [[ -e ${TARGET}/etc/resolv.conf || -L ${TARGET}/etc/resolv.conf ]]; then
        cp -a -- "${TARGET}/etc/resolv.conf" "${TARGET}/etc/resolv.conf.artix-iso" 2>/dev/null || true
        rm -f -- "${TARGET}/etc/resolv.conf"
    fi
    install -m 0644 -- "${source}" "${TARGET}/etc/resolv.conf"
}

mount_chroot_filesystems() {
    local source destination

    mkdir -p -- "${TARGET}/dev" "${TARGET}/proc" "${TARGET}/sys" "${TARGET}/run"

    if ! mountpoint -q -- "${TARGET}/dev"; then
        mount --rbind /dev "${TARGET}/dev"
        mount --make-rslave "${TARGET}/dev"
    fi

    if ! mountpoint -q -- "${TARGET}/proc"; then
        mount -t proc proc "${TARGET}/proc"
    fi

    for source in /sys /run; do
        destination="${TARGET}${source}"
        if ! mountpoint -q -- "${destination}"; then
            mount --rbind "${source}" "${destination}"
            mount --make-rslave "${destination}"
        fi
    done
}

unmount_chroot_filesystems() {
    local path
    canonicalize_target "$1"

    for path in run sys proc dev; do
        if mountpoint -q -- "${TARGET}/${path}"; then
            umount --recursive --lazy -- "${TARGET}/${path}"
        fi
    done
    log "Unmounted chroot filesystems below ${TARGET}"
}

write_metadata() {
    local iso_path="$1" iso_sha
    iso_sha="$(sha256sum "${iso_path}" | awk '{print $1}')"

    cat > "${TARGET}/.artix-chroot-source" <<EOF_META
ISO_URL=${ISO_URL}
ISO_FILE=${iso_path}
ISO_SHA256=${iso_sha}
ROOT_SOURCE=${ROOT_SOURCE}
CREATED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF_META
    chmod 0644 "${TARGET}/.artix-chroot-source"
}

enter_chroot() {
    local target_arg="$1"
    shift
    canonicalize_target "${target_arg}"
    [[ -f ${TARGET}/etc/os-release ]] || die "No prepared root filesystem found at ${TARGET}"
    disable_pacman_checkspace
    mount_chroot_filesystems
    prepare_resolver

    if (( $# == 0 )); then
        set -- /bin/bash -l
    fi

    log "Entering ${TARGET}"
    exec chroot "${TARGET}" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin \
        "$@"
}

main() {
    local args=() enter_command=() iso_path

    while (( $# > 0 )); do
        case "$1" in
            --iso-url)
                (( $# >= 2 )) || die "--iso-url requires a URL"
                ISO_URL="$2"
                shift 2
                ;;
            --cache-dir)
                (( $# >= 2 )) || die "--cache-dir requires a directory"
                CACHE_DIR="$2"
                shift 2
                ;;
            --refresh)
                REFRESH=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --enter)
                MODE="enter"
                shift
                (( $# > 0 )) || die "--enter requires TARGET"
                TARGET="$1"
                shift
                enter_command=("$@")
                break
                ;;
            --unmount)
                MODE="unmount"
                shift
                (( $# == 1 )) || die "--unmount requires exactly one TARGET"
                TARGET="$1"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                args+=("$@")
                break
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    require_root

    case "${MODE}" in
        enter)
            enter_chroot "${TARGET}" "${enter_command[@]}"
            ;;
        unmount)
            unmount_chroot_filesystems "${TARGET}"
            ;;
        setup)
            (( ${#args[@]} == 1 )) || { usage >&2; die "Setup requires exactly one TARGET"; }
            canonicalize_target "${args[0]}"
            [[ $(uname -m) == x86_64 ]] \
                || die "The selected ISO is x86_64; this host reports $(uname -m)"

            install_host_dependencies
            for command in curl gpg mount mountpoint findmnt rsync unsquashfs sha256sum chroot; do
                require_command "${command}"
            done

            WORK_DIR="$(mktemp -d -t artix-chroot.XXXXXXXX)"
            ISO_MOUNT="${WORK_DIR}/iso"
            obtain_iso
            iso_path="${ISO_PATH}"

            log "Mounting the ISO read-only"
            mount_readonly_image "${iso_path}" "${ISO_MOUNT}" \
                || die "Unable to mount the ISO: ${iso_path}"

            log "Detecting the live root filesystem"
            locate_root_filesystem "${ISO_MOUNT}" \
                || die "No mountable root filesystem image was found inside the ISO"
            log "Detected root filesystem: ${ROOT_SOURCE}"

            prepare_target_directory
            copy_root_filesystem
            disable_pacman_checkspace
            prepare_resolver
            write_metadata "${iso_path}"
            mount_chroot_filesystems

            log "Artix chroot prepared at ${TARGET}"
            printf '\nEnter it with:\n  sudo %q --enter %q\n' "$0" "${TARGET}"
            printf 'Unmount it with:\n  sudo %q --unmount %q\n' "$0" "${TARGET}"
            ;;
        *)
            die "Internal error: unknown mode ${MODE}"
            ;;
    esac
}

main "$@"
