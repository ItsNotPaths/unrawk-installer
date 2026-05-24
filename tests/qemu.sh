#!/usr/bin/env bash
# tests/qemu.sh — scaffold for end-to-end --for-real install testing.
#
# Why a separate harness:
#   --for-real refuses to run without /etc/unrawk-live-iso. That marker
#   exists only on the live ISO, never on the dev box. So the only safe
#   place to exercise the real subprocess path is inside a VM that
#   either *is* the live ISO or simulates it (chroot/container with
#   the marker file). This script prepares the target disk image; the
#   VM bootstrap itself is still manual (step 8 — ISO bundling — will
#   reuse the live ISO build for this).
#
# Workflow once a live ISO exists (step 8+):
#   1. ./tests/qemu.sh prepare        # builds target disk image
#   2. ./tests/qemu.sh boot <iso>     # boots VM with ISO + target attached
#   3. inside the VM, run:
#        unrawk-installer --headless --for-real --seed=/seed.txt
#   4. ./tests/qemu.sh verify         # mounts target and checks key files
#
# Until step 8 lands, this script covers (1) and (4) — and prints the
# qemu invocation for (2) for use against any live ISO you have.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${UNRAWK_QEMU_WORK:-$PROJECT_DIR/.qemu}"
TARGET_DISK="$WORK_DIR/target.raw"
MOUNT_POINT="$WORK_DIR/mnt"
DISK_SIZE="${UNRAWK_DISK_SIZE:-10G}"

mkdir -p "$WORK_DIR"

prepare() {
    echo "==> creating target disk: $TARGET_DISK ($DISK_SIZE)"
    if [ -f "$TARGET_DISK" ]; then
        echo "    (overwriting existing image)"
    fi
    qemu-img create -f raw "$TARGET_DISK" "$DISK_SIZE" >/dev/null
    echo "    done."
    echo
    echo "Use boot.sh next with an unrawk live ISO once one exists."
}

boot() {
    local iso="${1:-}"
    if [ -z "$iso" ] || [ ! -f "$iso" ]; then
        echo "error: pass an unrawk live ISO path" >&2
        echo "       usage: $0 boot <path/to/unrawk.iso>" >&2
        exit 2
    fi
    if [ ! -f "$TARGET_DISK" ]; then
        echo "error: run '$0 prepare' first" >&2
        exit 2
    fi
    echo "==> launching VM"
    echo "    boot the installer inside, then:"
    echo "    cp /path/to/seed /seed.txt"
    echo "    unrawk-installer --headless --for-real --seed=/seed.txt"
    echo
    exec qemu-system-x86_64 \
        -enable-kvm -m 2G -smp 2 \
        -bios /usr/share/ovmf/OVMF.fd \
        -cdrom "$iso" \
        -drive file="$TARGET_DISK",if=virtio,format=raw \
        -display gtk
}

verify() {
    if [ ! -f "$TARGET_DISK" ]; then
        echo "error: no target disk at $TARGET_DISK" >&2
        exit 2
    fi
    if [ "$(id -u)" -ne 0 ]; then
        echo "error: verify needs root (uses losetup + mount)" >&2
        echo "       try: sudo $0 verify" >&2
        exit 2
    fi

    mkdir -p "$MOUNT_POINT"
    echo "==> attaching loop device"
    local loop
    loop=$(losetup -fP --show "$TARGET_DISK")
    trap "umount '$MOUNT_POINT' 2>/dev/null; losetup -d '$loop' 2>/dev/null" EXIT

    echo "==> probing partitions"
    partprobe "$loop"
    ls "${loop}"p* || { echo "no partitions found"; exit 1; }

    # The cryptroot is on p2; we'd need the LUKS passphrase to open it.
    # For now just verify the partition table + ESP filesystem look right.
    echo "==> ESP contents:"
    mount "${loop}p1" "$MOUNT_POINT"
    ls -la "$MOUNT_POINT"
    umount "$MOUNT_POINT"

    echo
    echo "ok — partition table valid, ESP mountable."
    echo "(LUKS verify needs the passphrase; extend this script when needed.)"
}

case "${1:-help}" in
    prepare) prepare ;;
    boot)    boot "${2:-}" ;;
    verify)  verify ;;
    *)
        cat <<EOF
usage: $0 <prepare | boot <iso> | verify>

  prepare           build a fresh target disk image at $TARGET_DISK
  boot <iso>        launch qemu with the live ISO + target disk attached
  verify            (root) loop-mount the target disk, sanity-check layout

Env:
  UNRAWK_QEMU_WORK  working dir (default: \$PROJECT_DIR/.qemu)
  UNRAWK_DISK_SIZE  disk image size (default: 10G)
EOF
        ;;
esac
