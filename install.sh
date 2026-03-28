#!/bin/bash
###############################################################################
# Proxmox Backup — Remote Installer
#
# Run with:
#   curl -sSL https://raw.githubusercontent.com/MarkLFT/proxmox-backup/master/install.sh | bash
#
# Or download and inspect first:
#   curl -sSL -o install.sh https://raw.githubusercontent.com/MarkLFT/proxmox-backup/master/install.sh
#   less install.sh
#   bash install.sh
#
# What this does:
#   1. Checks prerequisites (root, Proxmox, git)
#   2. Asks for NAS connection details and backup schedule
#   3. Clones the repo to /opt/proxmox-backup
#   4. Generates proxmox-backup.conf from your answers
#   5. Tests the NAS mount
#   6. Runs an initial config harvest (dry-run)
#   7. Installs the cron job
#
###############################################################################

set -euo pipefail

INSTALL_DIR="/opt/proxmox-backup"
REPO_URL="https://github.com/MarkLFT/proxmox-backup.git"
CONF_FILE="${INSTALL_DIR}/proxmox-backup.conf"

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; }
ask()   { echo -en "${CYAN}[?]${NC} $*"; }

header() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
}

# ─── Prompt helpers ───────────────────────────────────────────────────────────

prompt() {
    # prompt "Question" "default_value" → sets REPLY
    local question="$1"
    local default="${2:-}"
    if [[ -n "$default" ]]; then
        ask "${question} [${default}]: "
        read -r REPLY < /dev/tty
        REPLY="${REPLY:-$default}"
    else
        ask "${question}: "
        read -r REPLY < /dev/tty
    fi
}

prompt_required() {
    # prompt_required "Question" "default_value" → sets REPLY, loops until non-empty
    local question="$1"
    local default="${2:-}"
    while true; do
        prompt "$question" "$default"
        [[ -n "$REPLY" ]] && return
        warn "This field is required."
    done
}

prompt_number() {
    # prompt_number "Question" "default" min max → sets REPLY, validates range
    local question="$1"
    local default="$2"
    local min="$3"
    local max="$4"
    while true; do
        prompt "$question" "$default"
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= min && REPLY <= max )); then
            return
        fi
        warn "Please enter a number between ${min} and ${max}."
    done
}

prompt_yn() {
    # prompt_yn "Question" "y" → returns 0 for yes, 1 for no
    local question="$1"
    local default="${2:-y}"
    local hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"

    ask "${question} ${hint}: "
    read -r REPLY < /dev/tty
    REPLY="${REPLY:-$default}"
    [[ "$REPLY" =~ ^[yY] ]]
}

prompt_choice() {
    # prompt_choice "Question" "opt1" "opt2" "opt3" → sets REPLY to chosen option
    local question="$1"; shift
    local options=("$@")
    echo ""
    ask "${question}"
    echo ""
    for i in "${!options[@]}"; do
        echo -e "    ${BOLD}$((i+1)))${NC} ${options[$i]}"
    done
    echo ""
    while true; do
        ask "Choice [1-${#options[@]}]: "
        read -r REPLY < /dev/tty
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= ${#options[@]} )); then
            REPLY="${options[$((REPLY-1))]}"
            return
        fi
        warn "Please enter a number between 1 and ${#options[@]}"
    done
}

# ─── Prerequisite checks ─────────────────────────────────────────────────────

header "Proxmox Backup — Installer"

echo "This will install the Proxmox backup system with:"
echo "  • Ansible-based host config harvesting (for disaster recovery)"
echo "  • vzdump VM/container backups"
echo "  • GFS (Grandfather-Father-Son) rotation"
echo "  • Automated daily cron job"
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
    error "This installer must be run as root."
    echo "  Try: curl -sSL <url> | sudo bash"
    exit 1
fi
info "Running as root"

# Check Proxmox
if ! command -v pveversion &>/dev/null; then
    error "Proxmox VE not detected (pveversion not found)."
    error "This script is designed for Proxmox VE hosts."
    exit 1
fi
PVE_VERSION=$(pveversion | grep -oP 'pve-manager/\K[^\s]+' || echo "unknown")
info "Proxmox VE detected: ${PVE_VERSION}"

# Check/install git
if ! command -v git &>/dev/null; then
    warn "git not found, installing..."
    apt-get update -qq && apt-get install -y -qq git > /dev/null
    info "git installed"
else
    info "git available"
fi

# Check vzdump
if ! command -v vzdump &>/dev/null; then
    error "vzdump not found. Is this a complete Proxmox VE installation?"
    exit 1
fi
info "vzdump available"

# ─── NAS Configuration ───────────────────────────────────────────────────────

header "NAS Configuration"

prompt_choice "How is your NAS connected?" "NFS" "SMB/CIFS" "Already mounted / local path"
NAS_TYPE="$REPLY"

NAS_MOUNT_POINT=""
NAS_SERVER=""
NAS_EXPORT=""
NAS_CIFS_SHARE=""
NAS_CIFS_USER=""
NAS_CIFS_PASS=""
FSTAB_ENTRY=""

case "$NAS_TYPE" in
    "NFS")
        echo ""
        # Install nfs-common if missing
        if ! dpkg -s nfs-common &>/dev/null; then
            warn "nfs-common not found, installing..."
            apt-get update -qq && apt-get install -y -qq nfs-common > /dev/null
            info "nfs-common installed"
        fi

        prompt_required "NAS hostname or IP address" ""
        NAS_SERVER="$REPLY"

        prompt_required "NFS export path (e.g., /volume1/backups)" ""
        NAS_EXPORT="$REPLY"

        prompt "Local mount point" "/mnt/nas-backup"
        NAS_MOUNT_POINT="$REPLY"

        FSTAB_ENTRY="${NAS_SERVER}:${NAS_EXPORT} ${NAS_MOUNT_POINT} nfs rw,soft,intr,timeo=300 0 0"
        ;;

    "SMB/CIFS")
        echo ""
        # Install cifs-utils if missing
        if ! dpkg -s cifs-utils &>/dev/null; then
            warn "cifs-utils not found, installing..."
            apt-get update -qq && apt-get install -y -qq cifs-utils > /dev/null
            info "cifs-utils installed"
        fi

        prompt_required "NAS hostname or IP address" ""
        NAS_SERVER="$REPLY"

        prompt_required "Share name (e.g., backups)" ""
        NAS_CIFS_SHARE="$REPLY"

        prompt "Username" "backup"
        NAS_CIFS_USER="$REPLY"

        ask "Password: "
        read -rs NAS_CIFS_PASS < /dev/tty
        echo ""

        prompt "Local mount point" "/mnt/nas-backup"
        NAS_MOUNT_POINT="$REPLY"

        FSTAB_ENTRY="//${NAS_SERVER}/${NAS_CIFS_SHARE} ${NAS_MOUNT_POINT} cifs username=${NAS_CIFS_USER},password=${NAS_CIFS_PASS},iocharset=utf8 0 0"
        ;;

    "Already mounted / local path")
        echo ""
        prompt "Path where backups should be stored" "/mnt/nas-backup"
        NAS_MOUNT_POINT="$REPLY"
        ;;
esac

BACKUP_BASE="${NAS_MOUNT_POINT}/proxmox"

# ─── Backup Settings ─────────────────────────────────────────────────────────

header "Backup Settings"

prompt_choice "vzdump backup mode" "snapshot (recommended — no VM downtime)" "suspend (brief pause)" "stop (VM stopped during backup)"
case "$REPLY" in
    snapshot*) VZDUMP_MODE="snapshot" ;;
    suspend*)  VZDUMP_MODE="suspend" ;;
    stop*)     VZDUMP_MODE="stop" ;;
esac

prompt_choice "Compression" "zstd (recommended — fast + good ratio)" "gzip (widely compatible)" "lzo (fastest, larger files)" "none"
case "$REPLY" in
    zstd*) VZDUMP_COMPRESS="zstd" ;;
    gzip*) VZDUMP_COMPRESS="gzip" ;;
    lzo*)  VZDUMP_COMPRESS="lzo" ;;
    none)  VZDUMP_COMPRESS="none" ;;
esac

# ─── GFS Retention ───────────────────────────────────────────────────────────

header "GFS Retention Policy"

echo "How many backups to keep at each tier:"
echo ""

prompt "Daily backups to keep" "7"
GFS_DAILY="$REPLY"

prompt "Weekly backups to keep" "4"
GFS_WEEKLY="$REPLY"

prompt "Monthly backups to keep" "6"
GFS_MONTHLY="$REPLY"

prompt_choice "Day of week for weekly backups" "Sunday" "Saturday" "Friday" "Monday"
case "$REPLY" in
    Sunday)    GFS_WEEKLY_DAY=7 ;;
    Saturday)  GFS_WEEKLY_DAY=6 ;;
    Friday)    GFS_WEEKLY_DAY=5 ;;
    Monday)    GFS_WEEKLY_DAY=1 ;;
esac

# ─── Schedule ─────────────────────────────────────────────────────────────────

header "Backup Schedule"

prompt_number "Hour to run daily backup (0-23, 24h format)" "2" 0 23
CRON_HOUR="$REPLY"

prompt_number "Minute (0-59)" "0" 0 59
CRON_MINUTE="$REPLY"

# ─── Notifications ────────────────────────────────────────────────────────────

header "Notifications"

NOTIFY_EMAIL=""
if prompt_yn "Enable email notifications?" "n"; then
    prompt "Email address" ""
    NOTIFY_EMAIL="$REPLY"
fi

# ─── Exclude VMs ──────────────────────────────────────────────────────────────

header "VM Exclusions"

echo "Current VMs and containers:"
echo ""
{
    echo "  TYPE     VMID   NAME                STATUS"
    echo "  ─────    ─────  ──────────────────  ──────"
    qm list 2>/dev/null | awk 'NR>1 {printf "  QEMU     %-6s %-20s %s\n", $1, $2, $3}' || true
    pct list 2>/dev/null | awk 'NR>1 {printf "  LXC      %-6s %-20s %s\n", $1, $3, $2}' || true
} 2>/dev/null
echo ""

EXCLUDE_VMIDS=""
if prompt_yn "Exclude any VMs/containers from backup?" "n"; then
    prompt "VMIDs to exclude (space-separated, e.g., 9000 9001)" ""
    EXCLUDE_VMIDS="$REPLY"
fi

# ─── Proxmox Storage ─────────────────────────────────────────────────────────

header "Proxmox Storage"

VZDUMP_STORAGE=""
CREATE_STORAGE=""
CREATE_STORAGE_NAME=""

echo "Using a Proxmox storage for VM backups means they appear in the"
echo "Proxmox web UI, so you can browse and restore them directly."
echo ""

# Find storages that support vzdump content
BACKUP_STORAGES=()
while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    BACKUP_STORAGES+=("$sid")
done < <(pvesm status --content backup 2>/dev/null | awk 'NR>1 {print $1}')

if [[ ${#BACKUP_STORAGES[@]} -gt 0 ]]; then
    echo "Existing storages that support backups:"
    echo ""
    for sid in "${BACKUP_STORAGES[@]}"; do
        stype=$(pvesm status -storage "$sid" 2>/dev/null | awk 'NR>1 {print $2}')
        sstatus=$(pvesm status -storage "$sid" 2>/dev/null | awk 'NR>1 {print $3}')
        echo -e "    ${BOLD}${sid}${NC} (${stype}, ${sstatus})"
    done
    echo ""
    if prompt_yn "Use one of these for VM backups?" "y"; then
        if [[ ${#BACKUP_STORAGES[@]} -eq 1 ]]; then
            VZDUMP_STORAGE="${BACKUP_STORAGES[0]}"
            info "Using '${VZDUMP_STORAGE}'"
        else
            prompt_choice "Which storage?" "${BACKUP_STORAGES[@]}"
            VZDUMP_STORAGE="$REPLY"
        fi
    fi
fi

if [[ -z "$VZDUMP_STORAGE" ]]; then
    # Default to yes for NFS/SMB (we just created the mount, likely no storage exists)
    local create_default="n"
    [[ "$NAS_TYPE" == "NFS" || "$NAS_TYPE" == "SMB/CIFS" ]] && create_default="y"

    if prompt_yn "Create a new Proxmox storage at ${NAS_MOUNT_POINT} for VM backups?" "$create_default"; then
        prompt "Storage name" "nas-backup"
        CREATE_STORAGE_NAME="$REPLY"
        CREATE_STORAGE="yes"
        VZDUMP_STORAGE="$CREATE_STORAGE_NAME"
    fi
fi

if [[ -z "$VZDUMP_STORAGE" ]]; then
    info "VM backups will be written to ${BACKUP_BASE}/<tier>/vm-backups/"
fi

# ─── Confirmation ─────────────────────────────────────────────────────────────

header "Installation Summary"

echo -e "  Install directory:   ${BOLD}${INSTALL_DIR}${NC}"
echo -e "  Backup destination:  ${BOLD}${BACKUP_BASE}${NC}"
echo -e "  NAS type:            ${BOLD}${NAS_TYPE}${NC}"
[[ -n "$NAS_SERVER" ]] && echo -e "  NAS server:          ${BOLD}${NAS_SERVER}${NC}"
echo -e "  vzdump mode:         ${BOLD}${VZDUMP_MODE}${NC}"
echo -e "  Compression:         ${BOLD}${VZDUMP_COMPRESS}${NC}"
[[ -n "$VZDUMP_STORAGE" ]] && echo -e "  Proxmox storage:     ${BOLD}${VZDUMP_STORAGE}${NC} (backups visible in UI)"
echo -e "  GFS retention:       ${BOLD}${GFS_DAILY}d / ${GFS_WEEKLY}w / ${GFS_MONTHLY}m${NC}"
echo -e "  Schedule:            ${BOLD}Daily at $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MINUTE")${NC}"
[[ -n "$NOTIFY_EMAIL" ]] && echo -e "  Notifications:       ${BOLD}${NOTIFY_EMAIL}${NC}"
[[ -n "$EXCLUDE_VMIDS" ]] && echo -e "  Excluded VMIDs:      ${BOLD}${EXCLUDE_VMIDS}${NC}"
echo ""

if ! prompt_yn "Proceed with installation?" "y"; then
    echo "Aborted."
    exit 0
fi

# ─── Install ──────────────────────────────────────────────────────────────────

header "Installing"

# Clone repo
if [[ -d "$INSTALL_DIR" ]]; then
    warn "Existing installation found at ${INSTALL_DIR}"
    if prompt_yn "Remove and reinstall?" "y"; then
        rm -rf "$INSTALL_DIR"
    else
        echo "Aborted."
        exit 0
    fi
fi

info "Cloning repository..."
git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" > /dev/null 2>&1
info "Cloned to ${INSTALL_DIR}"

# Make scripts executable
chmod +x "${INSTALL_DIR}/proxmox-backup.sh"
chmod +x "${INSTALL_DIR}/harvest-proxmox-config.sh"
chmod +x "${INSTALL_DIR}/recover-vms.sh"
chmod +x "${INSTALL_DIR}/install-cron.sh"
info "Scripts marked executable"

# Generate config file
info "Generating configuration..."
cat > "$CONF_FILE" <<CONF
###############################################################################
# proxmox-backup.conf — Generated by installer on $(date -Iseconds)
###############################################################################

# NAS mount point
BACKUP_BASE="${BACKUP_BASE}"

# GFS retention
GFS_DAILY_KEEP=${GFS_DAILY}
GFS_WEEKLY_KEEP=${GFS_WEEKLY}
GFS_MONTHLY_KEEP=${GFS_MONTHLY}
GFS_WEEKLY_DAY=${GFS_WEEKLY_DAY}

# vzdump settings
VZDUMP_STORAGE="${VZDUMP_STORAGE}"
VZDUMP_MODE="${VZDUMP_MODE}"
VZDUMP_COMPRESS="${VZDUMP_COMPRESS}"
VZDUMP_PIGZ=4
VZDUMP_BWLIMIT=0
VZDUMP_TMPDIR=""
VZDUMP_EXTRA_ARGS=""

# Excluded VMs
EXCLUDE_VMIDS="${EXCLUDE_VMIDS}"

# Notifications
NOTIFY_EMAIL="${NOTIFY_EMAIL}"
LOG_FILE="/var/log/proxmox-backup.log"

# Ansible config harvest
HARVEST_ENABLED=true
CONF
info "Config written to ${CONF_FILE}"

# Mount NAS if needed
if [[ -n "$FSTAB_ENTRY" ]]; then
    info "Setting up NAS mount..."
    mkdir -p "$NAS_MOUNT_POINT"

    # Add to fstab if not already present
    if ! grep -qF "$NAS_MOUNT_POINT" /etc/fstab; then
        # Store CIFS credentials securely if SMB
        if [[ "$NAS_TYPE" == "SMB/CIFS" ]]; then
            CRED_FILE="/etc/proxmox-backup-nas-credentials"
            cat > "$CRED_FILE" <<CRED
username=${NAS_CIFS_USER}
password=${NAS_CIFS_PASS}
CRED
            chmod 600 "$CRED_FILE"
            # Rewrite fstab entry to use credentials file instead of inline password
            FSTAB_ENTRY="//${NAS_SERVER}/${NAS_CIFS_SHARE} ${NAS_MOUNT_POINT} cifs credentials=${CRED_FILE},iocharset=utf8 0 0"
            info "CIFS credentials stored in ${CRED_FILE} (mode 600)"
        fi

        echo "$FSTAB_ENTRY" >> /etc/fstab
        info "Added to /etc/fstab"
    else
        warn "Mount point already in /etc/fstab, skipping"
    fi

    # Mount now
    if ! mountpoint -q "$NAS_MOUNT_POINT"; then
        if mount "$NAS_MOUNT_POINT"; then
            info "NAS mounted at ${NAS_MOUNT_POINT}"
        else
            error "Failed to mount NAS. Check your settings and try:"
            error "  mount ${NAS_MOUNT_POINT}"
            warn "Continuing installation — fix the mount before the first backup."
        fi
    else
        info "NAS already mounted at ${NAS_MOUNT_POINT}"
    fi
fi

# Create backup base directory
mkdir -p "$BACKUP_BASE"
info "Backup directory ready: ${BACKUP_BASE}"

# Register Proxmox storage if requested during configuration
if [[ "$CREATE_STORAGE" == "yes" ]]; then
    if pvesm add dir "$CREATE_STORAGE_NAME" --path "$NAS_MOUNT_POINT" --content vzdump 2>/dev/null; then
        info "Proxmox storage '${CREATE_STORAGE_NAME}' created at ${NAS_MOUNT_POINT}"
    else
        warn "Could not create Proxmox storage (it may already exist with a different config)."
        warn "You can add it manually: pvesm add dir ${CREATE_STORAGE_NAME} --path ${NAS_MOUNT_POINT} --content vzdump"
        VZDUMP_STORAGE=""
    fi
fi

# Configure retention on the Proxmox storage
if [[ -n "$VZDUMP_STORAGE" ]]; then
    PRUNE_SETTING="keep-daily=${GFS_DAILY},keep-weekly=${GFS_WEEKLY},keep-monthly=${GFS_MONTHLY}"
    if pvesm set "$VZDUMP_STORAGE" --prune-backups "$PRUNE_SETTING" 2>/dev/null; then
        info "Storage '${VZDUMP_STORAGE}' retention set: ${GFS_DAILY}d / ${GFS_WEEKLY}w / ${GFS_MONTHLY}m"
    else
        warn "Could not set retention on storage '${VZDUMP_STORAGE}'."
        warn "Set it manually: pvesm set ${VZDUMP_STORAGE} --prune-backups ${PRUNE_SETTING}"
    fi
fi

# Install cron job
info "Installing cron job..."
bash "${INSTALL_DIR}/install-cron.sh" --hour "$CRON_HOUR" --min "$CRON_MINUTE"
info "Cron job installed"

# ─── Initial harvest test ─────────────────────────────────────────────────────

header "Testing"

info "Running initial config harvest..."
if bash "${INSTALL_DIR}/harvest-proxmox-config.sh" "${INSTALL_DIR}/ansible/host_vars/pve.yml" > /dev/null 2>&1; then
    info "Host config harvested successfully"
    HARVEST_SIZE=$(du -sh "${INSTALL_DIR}/ansible/host_vars/pve.yml" | cut -f1)
    info "Ansible vars file: ${HARVEST_SIZE}"
else
    warn "Config harvest had warnings (this is normal on first run)"
fi

info "Running backup dry-run..."
bash "${INSTALL_DIR}/proxmox-backup.sh" --dry-run 2>&1 | tail -5

# ─── Done ─────────────────────────────────────────────────────────────────────

header "Installation Complete"

echo -e "  ${GREEN}Backups will run daily at $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MINUTE")${NC}"
echo ""
echo "  Useful commands:"
echo ""
echo -e "    ${BOLD}Run backup now:${NC}"
echo "      ${INSTALL_DIR}/proxmox-backup.sh"
echo ""
echo -e "    ${BOLD}Dry run (no changes):${NC}"
echo "      ${INSTALL_DIR}/proxmox-backup.sh --dry-run"
echo ""
echo -e "    ${BOLD}List available backups:${NC}"
echo "      ${INSTALL_DIR}/recover-vms.sh --list-backups"
echo ""
echo -e "    ${BOLD}Restore VMs from backup:${NC}"
echo "      ${INSTALL_DIR}/recover-vms.sh /mnt/nas-backup/proxmox/daily/YYYY-MM-DD"
echo ""
echo -e "    ${BOLD}Edit configuration:${NC}"
echo "      nano ${CONF_FILE}"
echo ""
echo -e "    ${BOLD}View logs:${NC}"
echo "      tail -f /var/log/proxmox-backup.log"
echo ""
echo -e "    ${BOLD}Update to latest version:${NC}"
echo "      cd ${INSTALL_DIR} && git pull"
echo ""
echo -e "    ${BOLD}Uninstall:${NC}"
echo "      ${INSTALL_DIR}/install-cron.sh --remove"
echo "      rm -rf ${INSTALL_DIR}"
echo ""

echo -e "  For disaster recovery (rebuild host from scratch):"
echo "    See: ${INSTALL_DIR}/README.md"
echo ""
