#!/bin/bash
###############################################################################
# harvest-proxmox-config.sh — Audit a running Proxmox host and generate
# an Ansible vars file compatible with the lae.proxmox role + custom extras.
#
# Usage:
#   ./harvest-proxmox-config.sh [output-file]
#   Default output: ./ansible/host_vars/pve.yml
#
# This captures the declarative config of the host — NOT VM disk images.
# Combined with the lae.proxmox Ansible role, this config can rebuild the
# host from a fresh Debian/Proxmox install.
###############################################################################

set -euo pipefail

OUTPUT="${1:-$(dirname "$0")/ansible/host_vars/pve.yml}"
TIMESTAMP=$(date -Iseconds)
HOSTNAME=$(hostname)

mkdir -p "$(dirname "$OUTPUT")"

# ─── Helper Functions ─────────────────────────────────────────────────────────

yaml_escape() {
    # Escape a string for YAML single-quoted scalar
    local s="$1"
    s="${s//\'/\'\'}"
    echo "'${s}'"
}

indent() {
    sed "s/^/$1/"
}

# ─── Gather Data ──────────────────────────────────────────────────────────────

gather_pve_version() {
    pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+' || echo "unknown"
}

gather_kernel() {
    uname -r
}

gather_hardware_fingerprint() {
    # Capture hardware-specific details so the recovery process can detect
    # mismatches when restoring to different hardware.

    echo "pve_hardware_fingerprint:"
    echo "  generated: $(date -Iseconds)"

    # CPU
    local cpu_model
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
    local cpu_cores
    cpu_cores=$(nproc)
    echo "  cpu_model: $(yaml_escape "$cpu_model")"
    echo "  cpu_cores: ${cpu_cores}"

    # RAM
    local ram_mb
    ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    echo "  ram_mb: ${ram_mb}"

    # Motherboard / system
    local sys_vendor sys_product
    sys_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "unknown")
    sys_product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
    echo "  system_vendor: $(yaml_escape "$sys_vendor")"
    echo "  system_product: $(yaml_escape "$sys_product")"

    # Network interface mapping: name → MAC, driver, PCI address
    echo "  network_interfaces:"
    for iface in /sys/class/net/*; do
        local name
        name=$(basename "$iface")
        [[ "$name" == "lo" ]] && continue
        local mac driver pci_addr
        mac=$(cat "$iface/address" 2>/dev/null || echo "unknown")
        driver=$(basename "$(readlink "$iface/device/driver" 2>/dev/null)" 2>/dev/null || echo "unknown")
        pci_addr=$(basename "$(readlink "$iface/device" 2>/dev/null)" 2>/dev/null || echo "unknown")
        echo "    - name: ${name}"
        echo "      mac: ${mac}"
        echo "      driver: ${driver}"
        echo "      pci_address: ${pci_addr}"
    done

    # Disk mapping: device → model, serial, size, by-id path
    echo "  disks:"
    lsblk -dnpo NAME,SIZE,MODEL,SERIAL,TYPE 2>/dev/null | while read -r dev size model serial dtype; do
        [[ "$dtype" == "disk" ]] || continue
        local byid=""
        # Find the /dev/disk/by-id/ symlink for this device
        for link in /dev/disk/by-id/*; do
            [[ -L "$link" ]] || continue
            [[ "$(readlink -f "$link")" == "$dev" ]] || continue
            # Prefer wwn- or scsi- links over ata- for stability
            byid=$(basename "$link")
            [[ "$byid" == wwn-* || "$byid" == scsi-* ]] && break
        done
        echo "    - device: ${dev}"
        echo "      size: ${size}"
        echo "      model: $(yaml_escape "${model:-unknown}")"
        echo "      serial: $(yaml_escape "${serial:-unknown}")"
        echo "      by_id: $(yaml_escape "${byid:-unknown}")"
    done

    # PCI devices (for passthrough reference)
    echo "  pci_devices:"
    { lspci -nn 2>/dev/null | grep -iE '(vga|3d|network|ethernet|nvme|raid|sas|audio)' || true; } | while read -r line; do
        local addr
        addr=$(echo "$line" | cut -d' ' -f1)
        local desc
        desc=$(echo "$line" | cut -d' ' -f2-)
        echo "    - address: '${addr}'"
        echo "      description: $(yaml_escape "$desc")"
    done
}

gather_network_interfaces() {
    # Parse /etc/network/interfaces into YAML
    local current_iface=""
    local in_iface=false

    echo "pve_network_interfaces:"
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^auto[[:space:]]+(.*) ]]; then
            continue
        elif [[ "$line" =~ ^iface[[:space:]]+([^ ]+)[[:space:]]+([^ ]+)[[:space:]]+([^ ]+) ]]; then
            current_iface="${BASH_REMATCH[1]}"
            local family="${BASH_REMATCH[2]}"
            local method="${BASH_REMATCH[3]}"
            echo "  - name: ${current_iface}"
            echo "    family: ${family}"
            echo "    method: ${method}"
            in_iface=true
        elif $in_iface && [[ "$line" =~ ^[[:space:]]+([a-z_-]+)[[:space:]]+(.*) ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            # Map common keys
            case "$key" in
                address)     echo "    address: ${val}" ;;
                netmask)     echo "    netmask: ${val}" ;;
                gateway)     echo "    gateway: ${val}" ;;
                bridge-ports|bridge_ports) echo "    bridge_ports: ${val}" ;;
                bridge-stp|bridge_stp)     echo "    bridge_stp: ${val}" ;;
                bridge-fd|bridge_fd)       echo "    bridge_fd: ${val}" ;;
                bridge-vlan-aware)         echo "    bridge_vlan_aware: ${val}" ;;
                mtu)         echo "    mtu: ${val}" ;;
                bond-slaves|bond_slaves)   echo "    bond_slaves: ${val}" ;;
                bond-mode|bond_mode)       echo "    bond_mode: ${val}" ;;
                dns-nameservers)           echo "    dns_nameservers: ${val}" ;;
                *)           echo "    ${key}: $(yaml_escape "$val")" ;;
            esac
        fi
    done < /etc/network/interfaces
}

gather_storage() {
    echo "pve_storages:"
    local current_storage=""

    if [[ ! -f /etc/pve/storage.cfg ]]; then
        echo "  []"
        return
    fi

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^([a-z]+):[[:space:]]*(.+) ]]; then
            local type="${BASH_REMATCH[1]}"
            current_storage="${BASH_REMATCH[2]}"
            echo "  - id: ${current_storage}"
            echo "    type: ${type}"
        elif [[ -n "$current_storage" && "$line" =~ ^[[:space:]]+([a-z_-]+)[[:space:]]+(.*) ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            echo "    ${key}: $(yaml_escape "$val")"
        fi
    done < /etc/pve/storage.cfg
}

gather_repos() {
    echo "pve_apt_repositories:"
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// /}" ]] && continue
            echo "  - $(yaml_escape "$line")"
        done < "$f"
    done
}

gather_installed_packages() {
    echo "pve_extra_packages:"
    # Capture manually-installed packages (not auto-installed dependencies)
    # Exclude proxmox/pve/ceph base packages — those come from the role
    comm -23 \
        <(apt-mark showmanual 2>/dev/null | sort) \
        <(dpkg-query -W -f='${Package}\n' 'proxmox-*' 'pve-*' 'ceph*' 'lib*' 2>/dev/null | sort) \
    | while read -r pkg; do
        echo "  - ${pkg}"
    done
}

gather_users_groups() {
    if [[ ! -f /etc/pve/user.cfg ]]; then
        return
    fi

    echo "pve_users:"
    { grep '^user:' /etc/pve/user.cfg || true; } | while IFS=: read -r _ userid enable expire firstname lastname email comment; do
        [[ "$userid" == "root@pam" ]] && continue
        echo "  - name: ${userid}"
        [[ -n "$enable" ]] && echo "    enable: ${enable}"
        [[ -n "$firstname" ]] && echo "    firstname: ${firstname}"
        [[ -n "$lastname" ]] && echo "    lastname: ${lastname}"
        [[ -n "$email" ]] && echo "    email: ${email}"
        [[ -n "$comment" ]] && echo "    comment: $(yaml_escape "$comment")"
    done

    echo ""
    echo "pve_groups:"
    { grep '^group:' /etc/pve/user.cfg || true; } | while IFS=: read -r _ groupid users comment; do
        echo "  - name: ${groupid}"
        [[ -n "$comment" ]] && echo "    comment: $(yaml_escape "$comment")"
        if [[ -n "$users" ]]; then
            echo "    members:"
            IFS=',' read -ra members <<< "$users"
            for m in "${members[@]}"; do
                echo "      - ${m}"
            done
        fi
    done

    echo ""
    echo "pve_acls:"
    { grep '^acl:' /etc/pve/user.cfg || true; } | while IFS=: read -r _ propagate path principal rolename; do
        echo "  - path: ${path}"
        echo "    principal: ${principal}"
        echo "    role: ${rolename}"
        echo "    propagate: ${propagate}"
    done
}

gather_firewall() {
    echo "pve_firewall_rules:"
    local fw_dir="/etc/pve/firewall"
    if [[ -d "$fw_dir" ]]; then
        for f in "$fw_dir"/*.fw; do
            [[ -f "$f" ]] || continue
            echo "  - file: $(basename "$f")"
            echo "    content: |"
            cat "$f" | indent "      "
        done
    else
        echo "  []"
    fi
}

gather_zfs() {
    if ! command -v zpool &>/dev/null; then
        return
    fi

    local pools
    pools=$(zpool list -H -o name 2>/dev/null) || return

    if [[ -z "$pools" ]]; then
        return
    fi

    echo "pve_zfs_pools:"
    while read -r pool; do
        [[ -z "$pool" ]] && continue
        local vdevs
        vdevs=$(zpool status "$pool" 2>/dev/null | awk '/config:/{found=1; next} found && /NAME/{next} found && /^$/{exit} found{print $1}' | head -20)
        echo "  - name: ${pool}"
        echo "    state: $(zpool get -H -o value health "$pool" 2>/dev/null || echo unknown)"
        echo "    properties:"
        for prop in ashift autotrim compression; do
            local val
            val=$(zpool get -H -o value "$prop" "$pool" 2>/dev/null || echo "-")
            echo "      ${prop}: ${val}"
        done
    done <<< "$pools"

    echo ""
    echo "pve_zfs_datasets:"
    zfs list -H -o name,mountpoint,compression,recordsize 2>/dev/null | while read -r name mp comp rs; do
        echo "  - name: ${name}"
        echo "    mountpoint: ${mp}"
        echo "    compression: ${comp}"
        echo "    recordsize: ${rs}"
    done
}

gather_fstab() {
    echo "pve_fstab_entries:"
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        # Parse: device mountpoint type options dump pass
        read -r dev mp fstype opts dump pass <<< "$line"
        # Skip proc/sysfs/devpts — those are system defaults
        [[ "$fstype" == "proc" || "$fstype" == "sysfs" || "$fstype" == "devpts" ]] && continue
        echo "  - device: $(yaml_escape "$dev")"
        echo "    mountpoint: ${mp}"
        echo "    fstype: ${fstype}"
        echo "    options: ${opts}"
        echo "    dump: ${dump:-0}"
        echo "    pass: ${pass:-0}"
    done < /etc/fstab
}

gather_sysctl() {
    echo "pve_sysctl_settings:"
    for f in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// /}" ]] && continue
            if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
                local key="${BASH_REMATCH[1]// /}"
                local val="${BASH_REMATCH[2]// /}"
                echo "  ${key}: $(yaml_escape "$val")"
            fi
        done < "$f"
    done
}

gather_modprobe() {
    echo "pve_modprobe_options:"
    for f in /etc/modprobe.d/*.conf; do
        [[ -f "$f" ]] || continue
        echo "  - file: $(basename "$f")"
        echo "    content: |"
        cat "$f" | indent "      "
    done

    echo ""
    echo "pve_modules_load:"
    if [[ -f /etc/modules ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// /}" ]] && continue
            echo "  - ${line}"
        done < /etc/modules
    fi
}

gather_cron_jobs() {
    echo "pve_cron_jobs:"
    for f in /etc/cron.d/*; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f")
        # Skip standard system crons
        [[ "$base" == "e2scrub_all" || "$base" == ".placeholder" ]] && continue
        echo "  - name: ${base}"
        echo "    content: |"
        cat "$f" | indent "      "
    done

    # Root's crontab
    if crontab -l &>/dev/null 2>&1; then
        echo "  - name: root-crontab"
        echo "    content: |"
        crontab -l 2>/dev/null | indent "      "
    fi
}

gather_vzdump_conf() {
    if [[ -f /etc/vzdump.conf ]]; then
        echo "pve_vzdump_conf: |"
        cat /etc/vzdump.conf | indent "  "
    fi
}

gather_datacenter_cfg() {
    if [[ -f /etc/pve/datacenter.cfg ]]; then
        echo "pve_datacenter_cfg:"
        while IFS=: read -r key val; do
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            key=$(echo "$key" | xargs)
            val=$(echo "$val" | xargs)
            echo "  ${key}: $(yaml_escape "$val")"
        done < /etc/pve/datacenter.cfg
    fi
}

gather_tailscale() {
    if ! command -v tailscale &>/dev/null; then
        echo "pve_tailscale_installed: false"
        return
    fi

    echo "pve_tailscale_installed: true"

    # Capture current node status
    local status
    status=$(tailscale status --json 2>/dev/null) || true
    if [[ -n "$status" ]]; then
        local hostname
        hostname=$(echo "$status" | jq -r '.Self.HostName // empty' 2>/dev/null) || true
        local tailnet_ip
        tailnet_ip=$(echo "$status" | jq -r '.TailscaleIPs[0] // empty' 2>/dev/null) || true
        local online
        online=$(echo "$status" | jq -r '.Self.Online // empty' 2>/dev/null) || true

        [[ -n "$hostname" ]] && echo "pve_tailscale_hostname: $(yaml_escape "$hostname")"
        [[ -n "$tailnet_ip" ]] && echo "pve_tailscale_ip: $(yaml_escape "$tailnet_ip")"
        [[ "$online" == "true" ]] && echo "pve_tailscale_online: true"
    fi

    # Capture advertised routes and preferences from prefs
    local prefs
    prefs=$(tailscale debug prefs 2>/dev/null) || true
    if [[ -n "$prefs" ]]; then
        local routes
        routes=$(echo "$prefs" | jq -r '.AdvertiseRoutes // [] | .[]' 2>/dev/null) || true
        if [[ -n "$routes" ]]; then
            echo "pve_tailscale_advertise_routes:"
            echo "$routes" | while read -r route; do
                echo "  - $(yaml_escape "$route")"
            done
        fi

        local exit_node
        exit_node=$(echo "$prefs" | jq -r '.AdvertisesExitNode // false' 2>/dev/null) || true
        [[ "$exit_node" == "true" ]] && echo "pve_tailscale_exit_node: true"

        local accept_routes
        accept_routes=$(echo "$prefs" | jq -r '.AcceptRoutes // false' 2>/dev/null) || true
        [[ "$accept_routes" == "true" ]] && echo "pve_tailscale_accept_routes: true"

        local accept_dns
        accept_dns=$(echo "$prefs" | jq -r '.CorpDNS // false' 2>/dev/null) || true
        [[ "$accept_dns" == "true" ]] && echo "pve_tailscale_accept_dns: true"

        local shields_up
        shields_up=$(echo "$prefs" | jq -r '.ShieldsUp // false' 2>/dev/null) || true
        [[ "$shields_up" == "true" ]] && echo "pve_tailscale_shields_up: true"
    fi

    # Document the recovery command
    echo "# Recovery: after installing tailscale, re-authenticate and restore config:"
    echo "# tailscale up --advertise-routes=<routes> --accept-routes [--advertise-exit-node]"
    echo "# Then approve the subnet routes in the Tailscale admin console."
}

gather_vm_inventory() {
    # Not for rebuilding VMs — just a manifest of what existed
    echo "pve_vm_inventory:"

    if command -v qm &>/dev/null; then
        qm list 2>/dev/null | awk 'NR>1 {printf "  - vmid: %s\n    name: %s\n    type: qemu\n    status: %s\n", $1, $2, $3}'
    fi

    if command -v pct &>/dev/null; then
        pct list 2>/dev/null | awk 'NR>1 {printf "  - vmid: %s\n    name: %s\n    type: lxc\n    status: %s\n", $1, $3, $2}'
    fi
}

# ─── Main: Generate YAML ─────────────────────────────────────────────────────

{
    cat <<HEADER
---
###############################################################################
# Proxmox Host Configuration — auto-generated by harvest-proxmox-config.sh
#
# Generated: ${TIMESTAMP}
# Hostname:  ${HOSTNAME}
# PVE:       $(gather_pve_version)
# Kernel:    $(gather_kernel)
#
# This file is designed for use with the lae.proxmox Ansible role and
# the proxmox-extras custom role. Edit as needed before running recovery.
###############################################################################

# ─── Basic Host Info ──────────────────────────────────────────────────────────
pve_hostname: ${HOSTNAME}
pve_version: $(yaml_escape "$(gather_pve_version)")
pve_kernel: $(yaml_escape "$(gather_kernel)")

# Set to true for single-node (non-clustered) setups
pve_cluster_enabled: false

# ─── Hardware Fingerprint (for migration detection) ─────────────────────────
# If restoring to different hardware, the recovery playbook uses this section
# to detect NIC name changes, disk path changes, and PCI address differences.
# Review and update the network_interface_map below before running recovery.
HEADER

    gather_hardware_fingerprint
    echo ""

    # Generate a network interface map that can be edited for new hardware
    echo "# ─── Network Interface Map (edit for hardware migration) ────────────────────"
    echo "# Maps logical role → physical interface name."
    echo "# If recovering to new hardware, update the 'target' values to match"
    echo "# the new server's interface names (check with: ip link show)"
    echo "pve_network_interface_map:"
    for iface in /sys/class/net/*; do
        name=$(basename "$iface")
        [[ "$name" == "lo" ]] && continue
        echo "  - source: ${name}    # Original interface on backed-up host"
        echo "    target: ${name}    # ← Change this if new hardware has different NIC names"
    done
    echo ""

    echo "# ─── Network Configuration ───────────────────────────────────────────────────"
    echo "# NOTE: Interface names below are from the ORIGINAL hardware."
    echo "# The recovery playbook will remap them using pve_network_interface_map above."

    gather_network_interfaces
    echo ""

    echo "# ─── APT Repositories ────────────────────────────────────────────────────────"
    gather_repos
    echo ""

    echo "# ─── Storage Backends ────────────────────────────────────────────────────────"
    gather_storage
    echo ""

    echo "# ─── ZFS Configuration ───────────────────────────────────────────────────────"
    gather_zfs
    echo ""

    echo "# ─── Mount Points (fstab) ────────────────────────────────────────────────────"
    gather_fstab
    echo ""

    echo "# ─── Users, Groups & ACLs ────────────────────────────────────────────────────"
    gather_users_groups
    echo ""

    echo "# ─── Firewall ────────────────────────────────────────────────────────────────"
    gather_firewall
    echo ""

    echo "# ─── Kernel Modules & sysctl ─────────────────────────────────────────────────"
    gather_modprobe
    echo ""
    gather_sysctl
    echo ""

    echo "# ─── Cron Jobs ───────────────────────────────────────────────────────────────"
    gather_cron_jobs
    echo ""

    echo "# ─── vzdump Defaults ─────────────────────────────────────────────────────────"
    gather_vzdump_conf
    echo ""

    echo "# ─── Datacenter Config ───────────────────────────────────────────────────────"
    gather_datacenter_cfg
    echo ""

    echo "# ─── Tailscale / VPN ─────────────────────────────────────────────────────────"
    gather_tailscale
    echo ""

    echo "# ─── Extra Packages ──────────────────────────────────────────────────────────"
    gather_installed_packages
    echo ""

    echo "# ─── VM/CT Inventory (reference only — VMs restored from vzdump backups) ────"
    gather_vm_inventory

} > "$OUTPUT"

echo "Ansible vars written to: $OUTPUT"
echo "Sections captured: network, storage, repos, ZFS, fstab, users/ACLs, firewall, kernel, cron, vzdump, datacenter, packages, VM inventory"
