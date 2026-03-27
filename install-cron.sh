#!/bin/bash
###############################################################################
# install-cron.sh — Install the proxmox-backup cron job
#
# Usage:
#   ./install-cron.sh                    # Install with default schedule (2:00 AM)
#   ./install-cron.sh --hour 3           # Install at 3:00 AM
#   ./install-cron.sh --hour 1 --min 30  # Install at 1:30 AM
#   ./install-cron.sh --remove           # Remove the cron job
#
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_FILE="/etc/cron.d/proxmox-backup"
BACKUP_SCRIPT="${SCRIPT_DIR}/proxmox-backup.sh"
HOUR=2
MINUTE=0
REMOVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hour)   HOUR="$2"; shift 2 ;;
        --min)    MINUTE="$2"; shift 2 ;;
        --remove) REMOVE=true; shift ;;
        --help|-h)
            head -12 "$0" | grep -E "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if $REMOVE; then
    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        echo "Removed cron job: ${CRON_FILE}"
    else
        echo "No cron job found at ${CRON_FILE}"
    fi
    exit 0
fi

# Validate
if [[ ! -f "$BACKUP_SCRIPT" ]]; then
    echo "Error: Backup script not found at ${BACKUP_SCRIPT}"
    exit 1
fi

chmod +x "$BACKUP_SCRIPT"
chmod +x "${SCRIPT_DIR}/harvest-proxmox-config.sh"
chmod +x "${SCRIPT_DIR}/recover-vms.sh"

# Create cron job
cat > "$CRON_FILE" <<EOF
# Proxmox backup with GFS rotation — installed by install-cron.sh
# Runs daily; the script determines which GFS tier (daily/weekly/monthly)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

${MINUTE} ${HOUR} * * *   root   ${BACKUP_SCRIPT} >> /var/log/proxmox-backup.log 2>&1
EOF

chmod 0644 "$CRON_FILE"

echo "Cron job installed: ${CRON_FILE}"
echo "Schedule: Daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE")"
echo "Script:   ${BACKUP_SCRIPT}"
echo ""
echo "The backup script will automatically determine the GFS tier:"
echo "  - 1st of month → monthly"
echo "  - Sundays       → weekly"
echo "  - Other days    → daily"
echo ""
echo "To test: ${BACKUP_SCRIPT} --dry-run"
