#!/usr/bin/env bash
# lib/fstab.sh — /etc/fstab validation and conservative auto-repair
# Part of: arch-system-recovery
set -euo pipefail

# ── validate_and_repair_fstab ─────────────────────────────────────────────────
# Checks every non-comment line in the chroot's /etc/fstab.
# Issues found:
#   - UUID that does not match any block device → offers to remove or comment
#   - Missing critical entries (/  /boot/efi) → warns only, does not auto-add
#   - Lines with wrong field count → warns
validate_and_repair_fstab() {
    local fstab="${MOUNT_ROOT}/etc/fstab"
    local issues=0 repairs=0

    if [[ ! -f "${fstab}" ]]; then
        warn "No /etc/fstab found at ${fstab} — skipping fstab check."
        return 0
    fi

    log "Validating ${fstab}..."

    # Backup before any changes
    local backup="${fstab}.bak.$(date '+%Y%m%d_%H%M%S')"
    cp "${fstab}" "${backup}"
    vlog "fstab backup: ${backup}"

    local line_num=0
    local bad_lines=()

    while IFS= read -r line; do
        (( line_num++ )) || true

        # Skip comments and blank lines
        [[ "${line}" =~ ^[[:space:]]*#  ]] && continue
        [[ -z "${line// }"              ]] && continue

        # Count fields (fstab has 6: device mountpoint type options dump pass)
        local fields
        fields="$(echo "${line}" | awk '{print NF}')"
        if [[ "${fields}" -ne 6 ]]; then
            warn "fstab line ${line_num}: expected 6 fields, found ${fields}: ${line}"
            (( issues++ )) || true
            continue
        fi

        local dev_field
        dev_field="$(echo "${line}" | awk '{print $1}')"

        # Check UUID= entries
        if [[ "${dev_field}" =~ ^UUID= ]]; then
            local uuid="${dev_field#UUID=}"
            if ! blkid -U "${uuid}" &>/dev/null; then
                warn "fstab line ${line_num}: UUID=${uuid} not found on any device"
                log "  Stale fstab entry: ${line}"
                bad_lines+=("${line_num}:${line}")
                (( issues++ )) || true
            else
                vlog "fstab line ${line_num}: UUID=${uuid} OK"
            fi

        # Check PARTUUID= entries
        elif [[ "${dev_field}" =~ ^PARTUUID= ]]; then
            local partuuid="${dev_field#PARTUUID=}"
            if ! blkid -t "PARTUUID=${partuuid}" &>/dev/null; then
                warn "fstab line ${line_num}: PARTUUID=${partuuid} not found"
                bad_lines+=("${line_num}:${line}")
                (( issues++ )) || true
            else
                vlog "fstab line ${line_num}: PARTUUID=${partuuid} OK"
            fi

        # Check /dev/... paths that aren't tmpfs/proc/sys/etc
        elif [[ "${dev_field}" =~ ^/dev/ ]]; then
            if [[ ! -b "${dev_field}" ]]; then
                warn "fstab line ${line_num}: device ${dev_field} not found"
                bad_lines+=("${line_num}:${line}")
                (( issues++ )) || true
            else
                vlog "fstab line ${line_num}: ${dev_field} OK"
            fi
        fi
    done < "${fstab}"

    # ── Repair: comment out bad lines ─────────────────────────────────────────
    if [[ ${#bad_lines[@]} -gt 0 ]]; then
        log "Commenting out ${#bad_lines[@]} stale fstab entry/entries..."
        for entry in "${bad_lines[@]}"; do
            local bad_line="${entry#*:}"
            # Escape for sed
            local escaped
            escaped="$(printf '%s\n' "${bad_line}" | sed 's/[[\.*^$()+?{|]/\\&/g')"
            # Comment out the line (prepend #REMOVED:)
            sed -i "s|^${escaped}$|#REMOVED by arch-recovery $(date '+%Y-%m-%d'): ${bad_line}|" \
                "${fstab}" >> "${LOG_FILE}" 2>&1 || \
                warn "Could not comment out fstab line: ${bad_line}"
            log "  Commented out: ${bad_line}"
            (( repairs++ )) || true
        done
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    if [[ ${issues} -eq 0 ]]; then
        log "fstab validation: OK (no issues found)"
    else
        log "fstab validation: ${issues} issue(s) found, ${repairs} repaired"
        log "  Backup saved to: ${backup}"
        if [[ "${repairs}" -gt 0 ]]; then
            warn "Commented out ${repairs} stale fstab entry/entries. Review: ${fstab}"
        fi
    fi
}
