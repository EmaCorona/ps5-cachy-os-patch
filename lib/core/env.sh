#!/usr/bin/env bash
# ==============================================================================
# lib/core/env.sh - Rilevamento mount rootfs, boot e block device
# ==============================================================================

detect_mounts() {
    # Se le variabili MOCK_ROOT o MOCK_BOOT sono già esportate (es. test sandbox), usale direttamente
    if [ -n "${MOCK_ROOT:-}" ] && [ -d "$MOCK_ROOT" ]; then
        CACHY_MNT="$MOCK_ROOT"
    else
        CACHY_MNT=""
    fi

    if [ -n "${MOCK_BOOT:-}" ] && [ -d "$MOCK_BOOT" ]; then
        BOOT_MNT="$MOCK_BOOT"
    else
        BOOT_MNT=""
    fi

    # Rilevamento tramite lsblk (escludendo i mount di sistema dell'host come / o /boot)
    if [ -z "$CACHY_MNT" ] || [ -z "$BOOT_MNT" ]; then
        for m in $(lsblk -rno MOUNTPOINTS 2>/dev/null | grep -E '^/(run/media|media|mnt)/'); do
            if [ -z "$CACHY_MNT" ] && [ -d "$m/etc" ] && [ -d "$m/usr" ]; then
                CACHY_MNT="$m"
            fi
            if [ -z "$BOOT_MNT" ] && [ -f "$m/bzImage" ]; then
                BOOT_MNT="$m"
            fi
        done
    fi

    # Fallback su directory tipiche di automount (/run/media o /media, inclusi suffissi cachyos1/boot1)
    if [ -z "$CACHY_MNT" ]; then
        for d in /run/media/*/cachyos* /media/*/cachyos* /run/media/*/* /media/*/* /mnt/*; do
            if [ -d "$d/etc" ] && [ -d "$d/usr" ]; then
                CACHY_MNT="$d"
                break
            fi
        done
    fi

    if [ -z "$BOOT_MNT" ]; then
        for d in /run/media/*/boot* /media/*/boot* /run/media/*/* /media/*/* /mnt/*; do
            if [ -f "$d/bzImage" ]; then
                BOOT_MNT="$d"
                break
            fi
        done
    fi

    # Rilevamento dispositivo a blocchi root
    ROOT_DEV=""
    if [ -n "${MOCK_ROOT:-}" ]; then
        ROOT_DEV=""
    else
        for m in $(lsblk -rno NAME,MOUNTPOINTS 2>/dev/null | grep -E "cachyos|/run/media/.*cachyos" | awk '{print $1}'); do
            if [ -b "/dev/$m" ]; then
                ROOT_DEV="/dev/$m"
                break
            fi
        done
        if [ -z "$ROOT_DEV" ] && [ -b "/dev/sda1" ]; then
            ROOT_DEV="/dev/sda1"
        fi
    fi

    # Rilevamento dispositivo a blocchi boot (FAT32, contiene bzImage)
    BOOT_DEV=""
    if [ -z "${MOCK_BOOT:-}" ] && [ -n "$BOOT_MNT" ]; then
        BOOT_DEV=$(findmnt -n -o SOURCE --target "$BOOT_MNT" 2>/dev/null | head -n 1 || true)
        if [ -z "$BOOT_DEV" ] || [ ! -b "$BOOT_DEV" ]; then
            BOOT_DEV=$(blkid -L boot 2>/dev/null || true)
        fi
        [ -n "$BOOT_DEV" ] && [ -b "$BOOT_DEV" ] || BOOT_DEV=""
    fi
    return 0
}
