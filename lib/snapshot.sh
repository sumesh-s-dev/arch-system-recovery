#!/usr/bin/env bash
# lib/snapshot.sh — BTRFS snapshot discovery, listing, and safe rollback
# Part of: arch-system-recovery
set -euo pipefail

# ── list_btrfs_snapshots ──────────────────────────────────────────────────────
# Lists all BTRFS subvolumes on the given device.
# Mounts at top-level (subvolid=5) to inspect subvolume layout.
list_btrfs_snapshots() {
    local dev="${1:?list_btrfs_snapshots requires a device}"

    local fstype
    fstype="$(blkid -s TYPE -o value "${dev}" 2>/dev/null || true)"
    if [[ "${fstype}" != "btrfs" ]]; then
        err "${dev} is not a BTRFS partition (detected: ${fstype:-unknown})"
        return 1
    fi

    local tmpdir
    tmpdir="$(mktemp -d /tmp/snap-list.XXXXXX)"

    if ! mount -o subvolid=5,ro "${dev}" "${tmpdir}" 2>/dev/null; then
        rmdir "${tmpdir}"
        die "Cannot mount ${dev} at top-level to list snapshots."
    fi

    echo "" >&2
    _c_bold; _c_cyan
    printf "  BTRFS Subvolumes on %s\n" "${dev}" >&2
    printf "  %-40s  %-12s  %s\n" "Name" "ID" "Path" >&2
    printf "  %-40s  %-12s  %s\n" "────────────────────────────────────────" \
        "────────────" "────" >&2
    _c_reset

    local count=0
    while IFS= read -r line; do
        local id path
        id="$(echo "${line}" | awk '{print $2}')"
        path="$(echo "${line}" | awk '{print $NF}')"
        _c_yellow; printf "  %-40s  %-12s  %s\n" "${path}" "${id}" "" >&2; _c_reset
        log "  snapshot: id=${id} path=${path}"
        (( count++ )) || true
    done < <(btrfs subvolume list "${tmpdir}" 2>/dev/null)

    echo "" >&2

    if [[ ${count} -eq 0 ]]; then
        warn "No BTRFS subvolumes found on ${dev}."
        echo "  This BTRFS filesystem has no subvolumes." >&2
    else
        printf "  %d subvolume(s) found.\n" "${count}" >&2
        echo "" >&2
        echo "  To roll back: sudo arch-recovery --rollback <name> --root ${dev}" >&2
    fi

    umount "${tmpdir}" 2>/dev/null || true
    rmdir  "${tmpdir}" 2>/dev/null || true
}

# ── rollback_snapshot ─────────────────────────────────────────────────────────
# Safely rolls back the root subvolume to a named BTRFS snapshot.
#
# Strategy:
#   1. Mount BTRFS top-level
#   2. Rename current @ (or @root) to @.broken-<timestamp>
#   3. Create a read-write snapshot of <target> named @
#   4. Unmount and confirm
#
# The original subvolume is NEVER deleted — it is renamed so the user
# can recover it again if the rollback itself causes problems.
_validate_snapshot_name() {
    local snapshot="${1:?_validate_snapshot_name requires a snapshot name}"
    local part

    [[ -n "${snapshot}" ]] || die "Snapshot name cannot be empty."
    [[ "${snapshot}" != /* ]] || die "Snapshot name must be relative to the BTRFS top-level mount."

    IFS='/' read -r -a parts <<< "${snapshot}"
    for part in "${parts[@]}"; do
        case "${part}" in
            ""|"."|"..")
                die "Unsafe snapshot name '${snapshot}'. Use the exact relative path reported by --list-snapshots."
                ;;
        esac
    done
}

rollback_snapshot() {
    local dev="${1:?rollback_snapshot requires a device}"
    local target_snap="${2:?rollback_snapshot requires a snapshot name}"

    local fstype
    fstype="$(blkid -s TYPE -o value "${dev}" 2>/dev/null || true)"
    [[ "${fstype}" == "btrfs" ]] || die "Rollback requires a BTRFS partition; ${dev} is ${fstype}"

    log "Starting BTRFS snapshot rollback on ${dev}"
    log "  Target snapshot: ${target_snap}"
    _validate_snapshot_name "${target_snap}"

    # ── Find current root subvolume name ──────────────────────────────────────
    local root_subvol
    root_subvol="$(detect_btrfs_subvol "${dev}" 2>/dev/null || echo "@")"
    [[ -z "${root_subvol}" ]] && root_subvol="@"
    log "  Current root subvolume: ${root_subvol}"

    # ── Mount top-level ───────────────────────────────────────────────────────
    local tmpdir
    tmpdir="$(mktemp -d /tmp/snap-rollback.XXXXXX)"
    mount -o subvolid=5 "${dev}" "${tmpdir}" >> "${LOG_FILE}" 2>&1 \
        || die "Cannot mount ${dev} at top-level for rollback."

    # ── Verify target snapshot exists ─────────────────────────────────────────
    if [[ ! -d "${tmpdir}/${target_snap}" ]]; then
        umount "${tmpdir}" 2>/dev/null || true
        rmdir  "${tmpdir}" 2>/dev/null || true
        die "Snapshot '${target_snap}' not found on ${dev}. Run --list-snapshots first."
    fi

    # ── Safety: rename current root subvolume ─────────────────────────────────
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    local backup_name="${root_subvol}.broken-${ts}"
    log "  Renaming ${root_subvol} → ${backup_name} (safety backup)"

    if [[ -d "${tmpdir}/${root_subvol}" ]]; then
        mv "${tmpdir}/${root_subvol}" "${tmpdir}/${backup_name}" \
            >> "${LOG_FILE}" 2>&1 \
            || die "Could not rename current root subvolume. Rollback aborted."
        log "  Current root preserved as: ${backup_name}"
    else
        warn "Current root subvolume '${root_subvol}' not found — skipping rename"
    fi

    # ── Create rw snapshot of target ──────────────────────────────────────────
    log "  Creating writable snapshot: ${target_snap} → ${root_subvol}"
    btrfs subvolume snapshot \
        "${tmpdir}/${target_snap}" \
        "${tmpdir}/${root_subvol}" \
        >> "${LOG_FILE}" 2>&1 \
        || {
            # Attempt to restore original on failure
            [[ -d "${tmpdir}/${backup_name}" ]] && \
                mv "${tmpdir}/${backup_name}" "${tmpdir}/${root_subvol}" \
                2>/dev/null || true
            umount "${tmpdir}" 2>/dev/null || true
            rmdir  "${tmpdir}" 2>/dev/null || true
            die "btrfs subvolume snapshot failed. Original preserved as ${backup_name}."
        }

    umount "${tmpdir}" >> "${LOG_FILE}" 2>&1 || true
    rmdir  "${tmpdir}" 2>/dev/null || true

    log "Rollback complete."
    _c_green; _c_bold
    printf "\n  ✓  Rolled back to: %s\n" "${target_snap}" >&2
    _c_reset
    printf "     Old subvolume preserved as: %s\n\n" "${backup_name}" >&2
    echo "     Reboot now to boot into the restored snapshot." >&2
    echo "" >&2
}
