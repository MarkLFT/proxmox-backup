#!/bin/bash
###############################################################################
# proxmox-backup.sh — Proxmox VE Host + VM Backup with GFS Rotation
#
# Backs up:
#   1. Host configuration — harvested into an Ansible vars file so the host
#      can be rebuilt from scratch with `lae.proxmox` + `community.proxmox`.
#   2. All VMs and LXC containers via vzdump.
#
# GFS (Grandfather-Father-Son) rotation:
#   - Daily   backups kept for N days
#   - Weekly  backups kept for N weeks  (taken on configurable day)
#   - Monthly backups kept for N months (taken on 1st of month)
#
# Prerequisites:
#   - Mount your NAS (NFS/SMB) before running
#   - Run as root
#
# Usage:
#   ./proxmox-backup.sh                    # Run with defaults
#   ./proxmox-backup.sh --config /path/to  # Use custom config file
#   ./proxmox-backup.sh --dry-run          # Show what would be done
#
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults (override via proxmox-backup.conf) ─────────────────────────────

BACKUP_BASE="/mnt/nas-backup/proxmox"
GFS_DAILY_KEEP=7
GFS_WEEKLY_KEEP=4
GFS_MONTHLY_KEEP=6
GFS_WEEKLY_DAY=7

VZDUMP_MODE="snapshot"
VZDUMP_COMPRESS="zstd"
VZDUMP_PIGZ=4
VZDUMP_BWLIMIT=0
VZDUMP_TMPDIR=""
VZDUMP_EXTRA_ARGS=""
EXCLUDE_VMIDS=""

NOTIFY_EMAIL=""
LOG_FILE="/var/log/proxmox-backup.log"
HARVEST_ENABLED=true
MIN_FREE_GB=50
MIN_FREE_GB=50

# ─── Parse arguments ─────────────────────────────────────────────────────────

DRY_RUN=false
CONFIG_FILE="${SCRIPT_DIR}/proxmox-backup.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)   CONFIG_FILE="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --help|-h)
            head -30 "$0" | grep -E "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# Source config file
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ─── Logging ──────────────────────────────────────────────────────────────────

log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ─── Validation ───────────────────────────────────────────────────────────────

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

check_mount() {
    # When using a named Proxmox storage, check and attempt to activate it
    if [[ -n "${VZDUMP_STORAGE:-}" ]]; then
        local storage_status
        storage_status=$(pvesm status -storage "$VZDUMP_STORAGE" 2>/dev/null | awk 'NR>1 {print $2}')
        if [[ "$storage_status" != "active" ]]; then
            log_warn "Storage '$VZDUMP_STORAGE' is not active (status: ${storage_status:-unknown}). Attempting to activate..."
            if pvesm set "$VZDUMP_STORAGE" --disable 0 &>/dev/null && \
               mount_output=$(pvesm mount "$VZDUMP_STORAGE" 2>&1); then
                # Re-check status after mount attempt
                storage_status=$(pvesm status -storage "$VZDUMP_STORAGE" 2>/dev/null | awk 'NR>1 {print $2}')
            fi
            if [[ "$storage_status" != "active" ]]; then
                log_error "Storage '$VZDUMP_STORAGE' could not be activated. Check your mount/NAS."
                exit 1
            fi
            log_info "Storage '$VZDUMP_STORAGE' is now active."
        else
            log_info "Storage '$VZDUMP_STORAGE' is active."
        fi
        return
    fi

    # Dumpdir mode: check the backup path is on a mounted filesystem
    if mountpoint -q "$(dirname "$BACKUP_BASE")" 2>/dev/null || \
       mountpoint -q "$BACKUP_BASE" 2>/dev/null; then
        return
    fi

    # Not mounted — try to mount via fstab
    log_warn "BACKUP_BASE '$BACKUP_BASE' is not on a mounted filesystem. Attempting to mount..."
    local mount_target
    mount_target=$(findmnt -n -o TARGET --fstab "$BACKUP_BASE" 2>/dev/null || \
                   findmnt -n -o TARGET --fstab "$(dirname "$BACKUP_BASE")" 2>/dev/null || true)

    if [[ -n "$mount_target" ]]; then
        if mount "$mount_target" 2>/dev/null; then
            log_info "Mounted $mount_target successfully."
            return
        fi
    fi

    log_error "BACKUP_BASE '$BACKUP_BASE' is not mounted and could not be mounted."
    log_error "Mount your NAS before running backups. Aborting."
    exit 1
}

check_disk_space() {
    local avail_kb
    avail_kb=$(df --output=avail "$BACKUP_BASE" 2>/dev/null | tail -1)
    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [[ "$avail_gb" -lt "$MIN_FREE_GB" ]]; then
        log_error "Only ${avail_gb}GB free on $(df --output=target "$BACKUP_BASE" | tail -1). Need at least ${MIN_FREE_GB}GB."
        exit 1
    fi
    log_info "Disk space check: ${avail_gb}GB available (minimum: ${MIN_FREE_GB}GB)"
}

check_dependencies() {
    for dep in vzdump tar date find; do
        if ! command -v "$dep" &>/dev/null; then
            log_error "Required command '$dep' not found."
            exit 1
        fi
    done

    if [[ -n "${VZDUMP_STORAGE:-}" ]]; then
        if ! pvesm status -storage "$VZDUMP_STORAGE" &>/dev/null; then
            log_error "VZDUMP_STORAGE '$VZDUMP_STORAGE' is not a valid Proxmox storage."
            exit 1
        fi
        log_info "Using Proxmox storage '$VZDUMP_STORAGE' for VM backups"
    fi
}

# ─── GFS Logic ────────────────────────────────────────────────────────────────

determine_gfs_tier() {
    local day_of_month day_of_week
    day_of_month=$(date +%-d)
    day_of_week=$(date +%u)

    if [[ "$day_of_month" -eq 1 ]]; then
        echo "monthly"
    elif [[ "$day_of_week" -eq "$GFS_WEEKLY_DAY" ]]; then
        echo "weekly"
    else
        echo "daily"
    fi
}

get_backup_dir() {
    local tier="$1"
    echo "${BACKUP_BASE}/${tier}/$(date +%Y-%m-%d)"
}

prune_old_backups() {
    local tier="$1"
    local keep="$2"
    local tier_dir="${BACKUP_BASE}/${tier}"

    [[ -d "$tier_dir" ]] || return

    local dirs=()
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && dirs+=("$dir")
    done < <(find "$tier_dir" -mindepth 1 -maxdepth 1 -type d | sort)

    local count=${#dirs[@]}
    local to_remove=$((count - keep))

    if [[ $to_remove -le 0 ]]; then
        log_info "Prune ${tier}: ${count} backups, keeping ${keep} — nothing to remove."
        return
    fi

    log_info "Prune ${tier}: ${count} backups, keeping ${keep}, removing ${to_remove}."
    for ((i = 0; i < to_remove; i++)); do
        if $DRY_RUN; then
            log_info "[DRY-RUN] Would remove: ${dirs[$i]}"
        else
            log_info "Removing old backup: ${dirs[$i]}"
            rm -rf "${dirs[$i]}"
        fi
    done
}

# ─── Ansible Config Harvest ──────────────────────────────────────────────────

harvest_host_config() {
    local dest_dir="$1"
    local harvest_script="${SCRIPT_DIR}/harvest-proxmox-config.sh"

    if [[ ! -f "$harvest_script" ]]; then
        log_error "Harvest script not found: $harvest_script"
        return 1
    fi

    local output="${dest_dir}/ansible-host-vars.yml"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would harvest host config to: $output"
        return
    fi

    log_info "Harvesting host configuration into Ansible vars..."
    if bash "$harvest_script" "$output"; then
        local size
        size=$(du -sh "$output" | cut -f1)
        log_info "Host config harvested: $output ($size)"

        # Also copy the latest to the ansible project for easy access
        local ansible_vars="${SCRIPT_DIR}/ansible/host_vars/pve.yml"
        mkdir -p "$(dirname "$ansible_vars")"
        cp "$output" "$ansible_vars"
        log_info "Updated ansible/host_vars/pve.yml with latest config."
    else
        log_error "Host config harvest failed."
        return 1
    fi
}

# ─── Host Config Files Backup ────────────────────────────────────────────────

backup_host_configs() {
    local dest_dir="$1"
    local archive="${dest_dir}/host-configs.tar.gz"

    # Directories to back up — these contain host-level service configs
    # that aren't captured by the Ansible vars harvest.
    local config_paths=(
        /etc/pve
        /etc/network
        /etc/modprobe.d
        /etc/modules-load.d
        /etc/sysctl.d
        /etc/apt/sources.list.d
        /etc/cron.d
        /etc/systemd/system
        /etc/netdata
        /etc/tailscale
        /etc/postfix
        /etc/ssh/sshd_config
        /etc/fstab
        /etc/hosts
        /etc/hostname
        /etc/resolv.conf
        /var/lib/tailscale/tailscaled.state
    )

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would archive host configs to: $archive"
        return
    fi

    # Build list of paths that actually exist
    local existing=()
    for p in "${config_paths[@]}"; do
        [[ -e "$p" ]] && existing+=("$p")
    done

    if [[ ${#existing[@]} -eq 0 ]]; then
        log_warn "No host config paths found to back up."
        return 1
    fi

    log_info "Backing up host config files..."
    if tar czf "$archive" "${existing[@]}" 2>/dev/null; then
        local size
        size=$(du -sh "$archive" | cut -f1)
        log_info "Host configs archived: $archive ($size)"
    else
        log_error "Host config archive failed."
        return 1
    fi
}

# ─── VM / LXC Backup ─────────────────────────────────────────────────────────

backup_vms() {
    local dest_dir="$1"

    # Build exclusion list
    local -A excluded
    for vmid in $EXCLUDE_VMIDS; do
        excluded[$vmid]=1
    done

    # Get list of all VMIDs
    local vmids=()
    while IFS= read -r vmid; do
        [[ -n "$vmid" ]] || continue
        if [[ -n "${excluded[$vmid]:-}" ]]; then
            log_info "Skipping excluded VMID $vmid"
            continue
        fi
        vmids+=("$vmid")
    done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}'; pct list 2>/dev/null | awk 'NR>1 {print $1}')

    if [[ ${#vmids[@]} -eq 0 ]]; then
        log_warn "No VMs or containers found to back up."
        return
    fi

    log_info "Backing up ${#vmids[@]} VM(s)/container(s): ${vmids[*]}"

    # Use named Proxmox storage if configured, otherwise write to dumpdir
    local vm_dir="${dest_dir}/vm-backups"
    if [[ -z "${VZDUMP_STORAGE:-}" ]]; then
        mkdir -p "$vm_dir"
    fi

    local failed=()
    for vmid in "${vmids[@]}"; do
        log_info "Backing up VMID $vmid..."

        local vzdump_cmd=(vzdump "$vmid"
            --mode "$VZDUMP_MODE"
            --compress "$VZDUMP_COMPRESS"
            --pigz "$VZDUMP_PIGZ"
        )

        if [[ -n "${VZDUMP_STORAGE:-}" ]]; then
            vzdump_cmd+=(--storage "$VZDUMP_STORAGE")
        else
            vzdump_cmd+=(--dumpdir "$vm_dir")
        fi

        [[ "$VZDUMP_BWLIMIT" -gt 0 ]] && vzdump_cmd+=(--bwlimit "$VZDUMP_BWLIMIT")
        [[ -n "$VZDUMP_TMPDIR" ]] && vzdump_cmd+=(--tmpdir "$VZDUMP_TMPDIR")
        # shellcheck disable=SC2206
        [[ -n "$VZDUMP_EXTRA_ARGS" ]] && vzdump_cmd+=($VZDUMP_EXTRA_ARGS)

        if $DRY_RUN; then
            log_info "[DRY-RUN] Would run: ${vzdump_cmd[*]}"
        else
            if "${vzdump_cmd[@]}" >> "$LOG_FILE" 2>&1; then
                log_info "VMID $vmid backup complete."
            else
                log_error "VMID $vmid backup FAILED."
                failed+=("$vmid")
            fi
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "Failed VM backups: ${failed[*]}"
        return 1
    fi
}

# ─── Notification ─────────────────────────────────────────────────────────────

send_notification() {
    local status="$1" tier="$2" dest_dir="$3"

    [[ -n "$NOTIFY_EMAIL" ]] || return

    local subject="Proxmox Backup ${status}: $(hostname) [${tier}] $(date +%Y-%m-%d)"
    local body
    body="Backup Status: ${status}\nHost: $(hostname)\nTier: ${tier}\n"
    body+="Destination: ${dest_dir}\nDate: $(date)\n\n"
    body+="--- Last 50 lines of log ---\n$(tail -50 "$LOG_FILE")"

    echo -e "$body" | mail -s "$subject" "$NOTIFY_EMAIL" 2>/dev/null || \
        log_warn "Failed to send email notification."
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local start_time
    start_time=$(date +%s)

    log_info "=========================================="
    log_info "Proxmox Backup Starting"
    log_info "=========================================="

    check_root
    check_dependencies
    check_mount
    check_disk_space

    local overall_status="SUCCESS"
    local using_storage=false
    [[ -n "${VZDUMP_STORAGE:-}" ]] && using_storage=true

    # Host configs always use GFS directories on BACKUP_BASE
    local tier
    tier=$(determine_gfs_tier)
    log_info "GFS tier for today: ${tier}"

    local dest_dir
    dest_dir=$(get_backup_dir "$tier")

    if ! $DRY_RUN; then
        mkdir -p "$dest_dir"
    fi

    # 1. Harvest host config into Ansible vars
    if [[ "$HARVEST_ENABLED" == "true" ]]; then
        if ! harvest_host_config "$dest_dir"; then
            overall_status="PARTIAL_FAILURE"
        fi
    fi

    # 2. Back up host config files
    if ! backup_host_configs "$dest_dir"; then
        overall_status="PARTIAL_FAILURE"
    fi

    # 3. Back up VMs and containers
    if ! backup_vms "$dest_dir"; then
        overall_status="PARTIAL_FAILURE"
    fi

    # 4. Write backup manifest
    if ! $DRY_RUN; then
        {
            echo "backup_date=$(date -Iseconds)"
            echo "hostname=$(hostname)"
            echo "proxmox_version=$(pveversion 2>/dev/null || echo unknown)"
            echo "kernel=$(uname -r)"
            echo "tier=${tier}"
            echo "backup_mode=${VZDUMP_MODE}"
            echo "compression=${VZDUMP_COMPRESS}"
            echo "vzdump_storage=${VZDUMP_STORAGE:-dumpdir}"
            echo "status=${overall_status}"
            echo "harvest_enabled=${HARVEST_ENABLED}"
        } > "${dest_dir}/backup-manifest.txt"
    fi

    # 5. Prune old backups
    if $using_storage; then
        # VM backup retention is managed by Proxmox storage prune-backups setting
        log_info "VM backup retention managed by Proxmox storage '${VZDUMP_STORAGE}'"
    fi
    # Host config GFS directories are always pruned by the script
    log_info "Pruning old host config backups..."
    prune_old_backups "daily"   "$GFS_DAILY_KEEP"
    prune_old_backups "weekly"  "$GFS_WEEKLY_KEEP"
    prune_old_backups "monthly" "$GFS_MONTHLY_KEEP"

    # Summary
    local end_time duration
    end_time=$(date +%s)
    duration=$(( end_time - start_time ))

    if ! $DRY_RUN && [[ -d "$dest_dir" ]]; then
        local total_size
        total_size=$(du -sh "$dest_dir" | cut -f1)
        log_info "Host config backup size: $total_size"
    fi

    log_info "Backup completed in $((duration / 60))m $((duration % 60))s — Status: ${overall_status}"
    log_info "=========================================="

    send_notification "$overall_status" "$tier" "$dest_dir"

    [[ "$overall_status" == "SUCCESS" ]] || exit 1
}

main "$@"
