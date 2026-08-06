#!/bin/sh
# DEEPX dx-runtime one-line installer (runtime-only: NPU driver + dx_rt + firmware)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/DEEPX-AI/dx-runtime/main/oneline-install.sh | sh
#
# Env overrides:
#   DX_REF=<branch|tag>   version manifest ref of dx-runtime (default: main)
set -eu

RAW_BASE="https://raw.githubusercontent.com/DEEPX-AI/dx-runtime"

log()  { printf '\033[1;34m[dx-runtime]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[dx-runtime][WARN]\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m[dx-runtime][ERROR]\033[0m %s\n' "$1" >&2; exit 1; }

DX_REF="${DX_REF:-main}"
# Trust boundary: DX_REF is spliced into a raw.githubusercontent.com URL below.
# curl normalizes ".." dot-segments client-side, so an unvalidated DX_REF can
# escape the hardcoded DEEPX-AI/dx-runtime prefix entirely. Allowlist safe
# git-ref characters and reject empty/leading-slash/".." outright.
case "$DX_REF" in
    ''|*..*|/*|*[!A-Za-z0-9._/-]*) die "invalid DX_REF: $DX_REF" ;;
esac

verify_sha256() {
    file="$1"; expected="$2"; label="$3"
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || die "checksum mismatch for ${label}: expected ${expected}, got ${actual}"
}

update_fw() {
    chip_id="$1"; chip_name="$2"; fw_bin="$3"
    if check_output="$(dxrt-cli "--check-${chip_id}" 2>&1)"; then
        log "Updating DX-${chip_name} firmware"
        dxrt-cli -g "$fw_bin" || die "DX-${chip_name} firmware version check failed"
        dxrt-cli -u "$fw_bin" || die "DX-${chip_name} firmware update failed"
        log "DX-${chip_name} firmware update completed"
    else
        warn "DX-${chip_name} check failed (dxrt-cli --check-${chip_id}): ${check_output}; skipping its firmware update"
    fi
}

main() {
    command -v curl >/dev/null 2>&1 || die "curl is required"
    command -v dpkg >/dev/null 2>&1 || die "Debian/Ubuntu (dpkg) is required"
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
        amd64|arm64) ;;
        *) die "unsupported architecture: $ARCH (amd64/arm64 only)" ;;
    esac

    SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || die "run as root or install sudo"
        SUDO="sudo"
    fi

    # world-readable so apt's sandbox user _apt can read the staged debs
    WORK="$(mktemp -d)"
    chmod 755 "$WORK"
    trap 'rm -rf "$WORK"' EXIT INT TERM

    log "Fetching version manifest (ref: $DX_REF)"
    curl -fsSL "$RAW_BASE/$DX_REF/oneline/versions.env" -o "$WORK/versions.env" \
        || die "failed to fetch version manifest ($RAW_BASE/$DX_REF/oneline/versions.env)"
    # shellcheck disable=SC1091 # dynamically fetched manifest, path is not constant
    . "$WORK/versions.env"

    case "$ARCH" in
        amd64) RT_DEB_URL="$RT_DEB_AMD64_URL" ;;
        arm64) RT_DEB_URL="$RT_DEB_ARM64_URL" ;;
    esac

    log "Downloading NPU driver ($DRIVER_TAG)"
    curl -fL "$DRIVER_DEB_URL" -o "$WORK/driver.deb"
    verify_sha256 "$WORK/driver.deb" "$SHA256_DRIVER_DEB" "NPU driver package"
    log "Downloading dx_rt ($RT_TAG, $ARCH)"
    curl -fL "$RT_DEB_URL" -o "$WORK/dxrt.deb"
    case "$ARCH" in
        amd64) verify_sha256 "$WORK/dxrt.deb" "$SHA256_RT_DEB_AMD64" "dx_rt package" ;;
        arm64) verify_sha256 "$WORK/dxrt.deb" "$SHA256_RT_DEB_ARM64" "dx_rt package" ;;
    esac
    log "Downloading firmware ($FW_TAG)"
    curl -fL "$FW_M1_URL"  -o "$WORK/fw_m1.bin"
    verify_sha256 "$WORK/fw_m1.bin" "$SHA256_FW_M1" "M1 firmware"
    curl -fL "$FW_M1M_URL" -o "$WORK/fw_m1m.bin"
    verify_sha256 "$WORK/fw_m1m.bin" "$SHA256_FW_M1M" "M1M firmware"
    curl -fL "$FW_H1_URL"  -o "$WORK/fw_h1.bin"
    verify_sha256 "$WORK/fw_h1.bin" "$SHA256_FW_H1" "H1 firmware"
    chmod 644 "$WORK"/*.deb

    log "Installing NPU driver (DKMS package)"
    $SUDO apt-get update -qq || true
    $SUDO apt-get install -y "$WORK/driver.deb"
    log "Installing dx_rt (libdxrt-bin)"
    $SUDO apt-get install -y "$WORK/dxrt.deb"

    if command -v dxrt-cli >/dev/null 2>&1; then
        update_fw m1  M1  "$WORK/fw_m1.bin"
        update_fw m1m M1M "$WORK/fw_m1m.bin"
        update_fw h1  H1  "$WORK/fw_h1.bin"
    else
        warn "dxrt-cli not found on PATH; skipping firmware update"
    fi

    log "Installation complete."
    log "A reboot is required to load the NPU driver:  sudo reboot"
    log "If firmware update was skipped (device not detected), rerun this script after reboot."
}

main "$@"
