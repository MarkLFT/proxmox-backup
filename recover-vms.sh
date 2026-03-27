#!/bin/bash
###############################################################################
# recover-vms.sh — Restore VMs and containers from a vzdump backup directory
#
# This is a standalone script that runs directly on the Proxmox host.
# For Ansible-based restore, use: ansible-playbook playbooks/restore-vms.yml
#
# Usage:
#   ./recover-vms.sh <backup-dir>                        # Restore all VMs
#   ./recover-vms.sh <backup-dir> --vmids 100,101,200    # Specific VMIDs
#   ./recover-vms.sh <backup-dir> --storage local-lvm    # Different storage
#   ./recover-vms.sh <backup-dir> --start                # Start after restore
#   ./recover-vms.sh <backup-dir> --force                # Overwrite existing
#   ./recover-vms.sh <backup-dir> --dry-run              # Show what would happen
#   ./recover-vms.sh --list-backups                      # List available backups
#
###############################################################################

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────

BACKUP_DIR=""
STORAGE="local"
VMID_FILTER=""
START_AFTER=false
FORCE=false
DRY_RUN=false
LIST_BACKUPS=false
BACKUP_BASE="/mnt/nas-backup/proxmox"

# ─── Parse arguments ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmids)       VMID_FILTER="$2"; shift 2 ;;
        --storage)     STORAGE="$2"; shift 2 ;;
        --start)       START_AFTER=true; shift ;;
        --force)       FORCE=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --list-backups) LIST_BACKUPS=true; shift ;;
        --help|-h)
            head -20 "$0" | grep -E "^#" | sed 's/^# \?//'
            exit 0
            ;;
        -*)            echo "Unknown option: $1"; exit 1 ;;
        *)             BACKUP_DIR="$1"; shift ;;
    esac
done

# ─── List available backups ───────────────────────────────────────────────────

if $LIST_BACKUPS; then
    echo "Available backups in ${BACKUP_BASE}:"
    echo ""
    for tier in monthly weekly daily; do
        tier_dir="${BACKUP_BASE}/${tier}"
        [[ -d "$tier_dir" ]] || continue
        echo "  ${tier}:"
        for d in "$tier_dir"/*/; do
            [[ -d "$d" ]] || continue
            local_date=$(basename "$d")
            vm_count=$(find "$d/vm-backups" -name "vzdump-*" -type f 2>/dev/null | wc -l)
            size=$(du -sh "$d" 2>/dev/null | cut -f1)
            has_ansible="no"
            [[ -f "$d/ansible-host-vars.yml" ]] && has_ansible="yes"
            echo "    ${local_date}  VMs: ${vm_count}  Size: ${size}  Ansible vars: ${has_ansible}"
        done
    done
    exit 0
fi

# ─── Validation ───────────────────────────────────────────────────────────────

if [[ -z "$BACKUP_DIR" ]]; then
    echo "Error: backup directory is required."
    echo "Usage: $0 <backup-dir> [options]"
    echo "       $0 --list-backups"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root."
    exit 1
fi

VM_BACKUP_DIR="${BACKUP_DIR}/vm-backups"
if [[ ! -d "$VM_BACKUP_DIR" ]]; then
    echo "Error: No vm-backups directory found in ${BACKUP_DIR}"
    exit 1
fi

# ─── Discover backup files ───────────────────────────────────────────────────

declare -a RESTORE_FILES=()

while IFS= read -r file; do
    [[ -n "$file" ]] && RESTORE_FILES+=("$file")
done < <(find "$VM_BACKUP_DIR" -type f \( -name "vzdump-qemu-*.vma*" -o -name "vzdump-qemu-*.zst" -o -name "vzdump-lxc-*.tar*" -o -name "vzdump-lxc-*.zst" \) | sort)

if [[ ${#RESTORE_FILES[@]} -eq 0 ]]; then
    echo "No vzdump backup files found in ${VM_BACKUP_DIR}"
    exit 1
fi

# Filter by VMID if requested
if [[ -n "$VMID_FILTER" ]]; then
    IFS=',' read -ra FILTER_IDS <<< "$VMID_FILTER"
    declare -a FILTERED=()
    for file in "${RESTORE_FILES[@]}"; do
        for vmid in "${FILTER_IDS[@]}"; do
            if [[ "$(basename "$file")" =~ vzdump-(qemu|lxc)-${vmid}- ]]; then
                FILTERED+=("$file")
                break
            fi
        done
    done
    RESTORE_FILES=("${FILTERED[@]}")
fi

# ─── Show restore plan ───────────────────────────────────────────────────────

echo "============================================"
echo "  Proxmox VM Restore"
echo "============================================"
echo ""
echo "  Backup dir:     ${BACKUP_DIR}"
echo "  Target storage: ${STORAGE}"
echo "  Force:          ${FORCE}"
echo "  Start after:    ${START_AFTER}"
echo "  Files:          ${#RESTORE_FILES[@]}"
echo ""

# Show manifest if available
if [[ -f "${BACKUP_DIR}/backup-manifest.txt" ]]; then
    echo "  Backup manifest:"
    while IFS='=' read -r key val; do
        echo "    ${key}: ${val}"
    done < "${BACKUP_DIR}/backup-manifest.txt"
    echo ""
fi

echo "  Files to restore:"
for file in "${RESTORE_FILES[@]}"; do
    local_base=$(basename "$file")
    local_size=$(du -sh "$file" | cut -f1)
    echo "    ${local_base} (${local_size})"
done
echo ""

if $DRY_RUN; then
    echo "[DRY-RUN] No changes will be made."
    exit 0
fi

# Confirmation prompt (skip if non-interactive)
if [[ -t 0 ]]; then
    read -rp "Proceed with restore? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { echo "Aborted."; exit 0; }
fi

# ─── Restore ──────────────────────────────────────────────────────────────────

FAILED=()
RESTORED=0

for file in "${RESTORE_FILES[@]}"; do
    local_base=$(basename "$file")
    echo ""
    echo "--- Restoring: ${local_base} ---"

    # Extract VMID and type
    if [[ "$local_base" =~ vzdump-qemu-([0-9]+)- ]]; then
        vmid="${BASH_REMATCH[1]}"
        vm_type="qemu"
    elif [[ "$local_base" =~ vzdump-lxc-([0-9]+)- ]]; then
        vmid="${BASH_REMATCH[1]}"
        vm_type="lxc"
    else
        echo "  WARNING: Cannot parse VMID from filename, skipping."
        FAILED+=("$local_base")
        continue
    fi

    # Check if VMID already exists
    if [[ "$vm_type" == "qemu" ]] && qm status "$vmid" &>/dev/null; then
        if $FORCE; then
            echo "  VMID $vmid exists, stopping and destroying (--force)..."
            qm stop "$vmid" --timeout 60 2>/dev/null || true
            qm destroy "$vmid" --purge 2>/dev/null || true
        else
            echo "  WARNING: VMID $vmid already exists. Use --force to overwrite. Skipping."
            FAILED+=("$local_base")
            continue
        fi
    fi

    if [[ "$vm_type" == "lxc" ]] && pct status "$vmid" &>/dev/null; then
        if $FORCE; then
            echo "  VMID $vmid exists, stopping and destroying (--force)..."
            pct stop "$vmid" 2>/dev/null || true
            pct destroy "$vmid" --purge 2>/dev/null || true
        else
            echo "  WARNING: VMID $vmid already exists. Use --force to overwrite. Skipping."
            FAILED+=("$local_base")
            continue
        fi
    fi

    # Restore
    if [[ "$vm_type" == "qemu" ]]; then
        if qmrestore "$file" --storage "$STORAGE"; then
            echo "  QEMU VM $vmid restored successfully."
            ((RESTORED++))

            if $START_AFTER; then
                echo "  Starting VM $vmid..."
                qm start "$vmid" || echo "  WARNING: Failed to start VM $vmid"
            fi
        else
            echo "  ERROR: Failed to restore QEMU VM $vmid"
            FAILED+=("$local_base")
        fi
    elif [[ "$vm_type" == "lxc" ]]; then
        if pct restore "$vmid" "$file" --storage "$STORAGE"; then
            echo "  LXC container $vmid restored successfully."
            ((RESTORED++))

            if $START_AFTER; then
                echo "  Starting container $vmid..."
                pct start "$vmid" || echo "  WARNING: Failed to start container $vmid"
            fi
        else
            echo "  ERROR: Failed to restore LXC container $vmid"
            FAILED+=("$local_base")
        fi
    fi
done

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  Restore Complete"
echo "============================================"
echo "  Restored: ${RESTORED}"
echo "  Failed:   ${#FAILED[@]}"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    echo "  Failed files:"
    for f in "${FAILED[@]}"; do
        echo "    - ${f}"
    done
    exit 1
fi
