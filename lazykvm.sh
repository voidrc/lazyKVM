#!/usr/bin/env bash
# lazykvm — Single-file QEMU/KVM manager
# Usage: lazykvm [command] [args...]
#        lazykvm          (interactive menu)

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── Helpers ──────────────────────────────────────────────────────────────────
info()    { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
err()     { echo -e "${RED}[✗]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

require() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || { err "Required command not found: $cmd"; exit 1; }
    done
}

# Default folder layout under ~/KVM
KVM_ROOT="${HOME}/KVM"
KVM_ISO_DIR="${KVM_ROOT}/iso"
KVM_IMAGES_DIR="${KVM_ROOT}/images"
KVM_SNAPS_DIR="${KVM_ROOT}/snaps"
KVM_EXPORTS_DIR="${KVM_ROOT}/exports"
KVM_NETS_DIR="${KVM_ROOT}/nets"
KVM_CONFIG_FILE="${KVM_ROOT}/.conf"

POOL_ISO_NAME="kvm-iso"
POOL_IMAGES_NAME="kvm-images"
POOL_SNAPS_NAME="kvm-snaps"
POOL_EXPORTS_NAME="kvm-exports"

LIBVIRT_POLICY="manual"

load_runtime_state() {
    if [[ -f "$KVM_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$KVM_CONFIG_FILE"
    fi
}

save_runtime_state() {
    mkdir -p "$KVM_ROOT"
    cat >"$KVM_CONFIG_FILE" <<EOF
LIBVIRT_POLICY="${LIBVIRT_POLICY}"
EOF
}

detect_libvirt_service() {
    local candidate
    for candidate in libvirtd.service virtqemud.service; do
        if systemctl list-unit-files "$candidate" --no-legend 2>/dev/null | grep -q "^${candidate}"; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

manage_libvirt_daemon() {
    command -v systemctl &>/dev/null || {
        warn "systemctl not found; skipping daemon setup."
        return 0
    }

    local svc=""
    if ! svc="$(detect_libvirt_service)"; then
        warn "Could not find libvirtd/virtqemud systemd unit; skipping daemon setup."
        return 0
    fi

    echo ""
    echo "  Libvirt daemon setup for ${svc}:"
    echo "   1) Enable autostart + start now"
    echo "   2) Start now only"
    echo "   3) Skip"
    read -rp "  Choice [2]: " daemon_choice
    daemon_choice="${daemon_choice:-2}"

    case "$daemon_choice" in
        1)
            if systemctl enable --now "$svc" 2>/dev/null; then
                info "Enabled autostart and started $svc"
                LIBVIRT_POLICY="autostart"
                save_runtime_state
            else
                warn "Failed to enable/start $svc (try: sudo systemctl enable --now $svc)"
            fi
            ;;
        2)
            if systemctl start "$svc" 2>/dev/null; then
                info "Started $svc"
                LIBVIRT_POLICY="start-only"
                save_runtime_state
            else
                warn "Failed to start $svc (try: sudo systemctl start $svc)"
            fi
            ;;
        3)
            info "Skipped daemon management."
            LIBVIRT_POLICY="manual"
            save_runtime_state
            ;;
        *)
            warn "Invalid choice; skipping daemon management."
            ;;
    esac
}

ensure_libvirt_daemon_if_needed() {
    [[ "${LIBVIRT_POLICY}" == "start-only" ]] || return 0

    command -v systemctl &>/dev/null || {
        warn "systemctl not found; cannot enforce start-only daemon policy."
        return 0
    }

    local svc=""
    if ! svc="$(detect_libvirt_service)"; then
        warn "Libvirt daemon unit not found; cannot enforce start-only policy."
        return 0
    fi

    if ! systemctl is-active --quiet "$svc"; then
        warn "Libvirt daemon is not running; attempting to start $svc..."
        if systemctl start "$svc" 2>/dev/null; then
            info "Started $svc"
        else
            warn "Failed to start $svc (try: sudo systemctl start $svc)"
        fi
    fi
}

ensure_pool() {
    local pool_name="$1" pool_path="$2"

    if ! virsh pool-info "$pool_name" &>/dev/null; then
        virsh pool-define-as --name "$pool_name" --type dir --target "$pool_path" >/dev/null
        info "Defined storage pool '$pool_name' -> $pool_path"
    fi

    virsh pool-build "$pool_name" >/dev/null 2>&1 || true
    virsh pool-start "$pool_name" >/dev/null 2>&1 || true
    virsh pool-autostart "$pool_name" >/dev/null 2>&1 || true
}

cmd_init() {
    mkdir -p "$KVM_ISO_DIR" "$KVM_IMAGES_DIR" "$KVM_SNAPS_DIR" "$KVM_EXPORTS_DIR" "$KVM_NETS_DIR"

    ensure_pool "$POOL_ISO_NAME" "$KVM_ISO_DIR"
    ensure_pool "$POOL_IMAGES_NAME" "$KVM_IMAGES_DIR"
    ensure_pool "$POOL_SNAPS_NAME" "$KVM_SNAPS_DIR"
    ensure_pool "$POOL_EXPORTS_NAME" "$KVM_EXPORTS_DIR"

    info "Initialized KVM folders:"
    echo "  - $KVM_ISO_DIR"
    echo "  - $KVM_IMAGES_DIR"
    echo "  - $KVM_SNAPS_DIR"
    echo "  - $KVM_EXPORTS_DIR"
    echo "  - $KVM_NETS_DIR"
    info "Pool mapping: iso=$POOL_ISO_NAME images=$POOL_IMAGES_NAME snaps=$POOL_SNAPS_NAME exports=$POOL_EXPORTS_NAME"

    manage_libvirt_daemon
}

show_dir_options() {
    local dir="$1" pattern="$2"
    local -n out_ref="$3"

    mapfile -t out_ref < <(find "$dir" -maxdepth 1 -type f -iname "$pattern" -printf "%f\n" | sort)
    if [[ ${#out_ref[@]} -eq 0 ]]; then
        warn "No matching files found in $dir"
        return 1
    fi

    echo "  Available in $dir:"
    local i=1
    for item in "${out_ref[@]}"; do
        echo "   $i) $item"
        ((i++))
    done
    return 0
}

load_runtime_state
ensure_libvirt_daemon_if_needed
require virsh

# ─── VM Listing ───────────────────────────────────────────────────────────────
cmd_list() {
    header "All Virtual Machines"
    virsh list --all
}

cmd_running() {
    header "Running VMs"
    virsh list --state-running
}

# ─── VM Lifecycle ─────────────────────────────────────────────────────────────
cmd_start() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm start <vm-name>"; exit 1; }
    info "Starting $vm..."
    virsh start "$vm"
}

cmd_stop() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm stop <vm-name>"; exit 1; }
    info "Gracefully shutting down $vm..."
    virsh shutdown "$vm"
}

cmd_kill() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm kill <vm-name>"; exit 1; }
    warn "Force destroying $vm..."
    virsh destroy "$vm"
}

cmd_reboot() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm reboot <vm-name>"; exit 1; }
    info "Rebooting $vm..."
    virsh reboot "$vm"
}

cmd_pause() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm pause <vm-name>"; exit 1; }
    info "Suspending $vm..."
    virsh suspend "$vm"
}

cmd_resume() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm resume <vm-name>"; exit 1; }
    info "Resuming $vm..."
    virsh resume "$vm"
}

# ─── VM Info ──────────────────────────────────────────────────────────────────
cmd_info() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm info <vm-name>"; exit 1; }
    header "Info: $vm"
    virsh dominfo "$vm"
    echo
    header "vCPU stats"
    virsh vcpuinfo "$vm" 2>/dev/null || true
    echo
    header "Network interfaces"
    virsh domiflist "$vm" 2>/dev/null || true
    echo
    header "Disk devices"
    virsh domblklist "$vm" 2>/dev/null || true
}

cmd_stats() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm stats <vm-name>"; exit 1; }
    header "Live stats: $vm"
    virsh domstats "$vm"
}

# ─── Snapshots ────────────────────────────────────────────────────────────────
cmd_snap_list() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm snap-list <vm-name>"; exit 1; }
    header "Snapshots: $vm"
    virsh snapshot-list "$vm"
}

cmd_snap_create() {
    local vm="${1:-}" name="${2:-}"
    [[ -z "$vm" || -z "$name" ]] && { err "Usage: lazykvm snap-create <vm-name> <snap-name>"; exit 1; }
    info "Creating snapshot '$name' for $vm..."
    virsh snapshot-create-as "$vm" "$name" --description "Created $(date '+%F %T')"
}

cmd_snap_revert() {
    local vm="${1:-}" name="${2:-}"
    [[ -z "$vm" || -z "$name" ]] && { err "Usage: lazykvm snap-revert <vm-name> <snap-name>"; exit 1; }
    warn "Reverting $vm to snapshot '$name'..."
    virsh snapshot-revert "$vm" "$name"
}

cmd_snap_delete() {
    local vm="${1:-}" name="${2:-}"
    [[ -z "$vm" || -z "$name" ]] && { err "Usage: lazykvm snap-delete <vm-name> <snap-name>"; exit 1; }
    warn "Deleting snapshot '$name' from $vm..."
    virsh snapshot-delete "$vm" "$name"
}

# ─── Cloning ──────────────────────────────────────────────────────────────────
cmd_clone() {
    local src="${1:-}" dst="${2:-}"
    [[ -z "$src" || -z "$dst" ]] && { err "Usage: lazykvm clone <source-vm> <new-vm>"; exit 1; }
    require virt-clone
    info "Cloning $src → $dst..."
    virt-clone --original "$src" --name "$dst" --auto-clone
}

# ─── VM Creation ──────────────────────────────────────────────────────────────
cmd_create() {
    require virt-install
    header "Create a New VM (interactive)"

    [[ -d "$KVM_ISO_DIR" && -d "$KVM_IMAGES_DIR" && -d "$KVM_SNAPS_DIR" && -d "$KVM_EXPORTS_DIR" ]] || {
        warn "Default KVM folders are missing. Run: lazykvm init"
        exit 1
    }

    echo "  Default paths:"
    echo "   - ISO     : $KVM_ISO_DIR"
    echo "   - Images  : $KVM_IMAGES_DIR"
    echo "   - Snaps   : $KVM_SNAPS_DIR"
    echo "   - Exports : $KVM_EXPORTS_DIR"

    read -rp "  VM name      : " vm_name
    read -rp "  vCPUs        : " vm_vcpus
    read -rp "  RAM (MB)     : " vm_ram
    read -rp "  Disk size(GB): " vm_disk

    local vm_iso=""
    local iso_choices=()
    if show_dir_options "$KVM_ISO_DIR" "*.iso" iso_choices; then
        read -rp "  ISO choice number (or press Enter for manual path): " iso_idx
        if [[ -n "${iso_idx:-}" ]]; then
            if [[ "$iso_idx" =~ ^[0-9]+$ ]] && (( iso_idx >= 1 && iso_idx <= ${#iso_choices[@]} )); then
                vm_iso="${KVM_ISO_DIR}/${iso_choices[$((iso_idx-1))]}"
            else
                err "Invalid ISO selection index"
                exit 1
            fi
        else
            read -rp "  ISO path     : " vm_iso
        fi
    else
        read -rp "  ISO path     : " vm_iso
    fi

    local image_choices=()
    local vm_disk_arg="path=${KVM_IMAGES_DIR}/${vm_name}.qcow2,size=${vm_disk},format=qcow2"
    if show_dir_options "$KVM_IMAGES_DIR" "*" image_choices; then
        read -rp "  Use existing disk image from list? [y/N]: " use_existing
        if [[ "$use_existing" =~ ^[Yy]$ ]]; then
            read -rp "  Image choice number: " img_idx
            if [[ "$img_idx" =~ ^[0-9]+$ ]] && (( img_idx >= 1 && img_idx <= ${#image_choices[@]} )); then
                vm_disk_arg="path=${KVM_IMAGES_DIR}/${image_choices[$((img_idx-1))]}"
            else
                err "Invalid image selection index"
                exit 1
            fi
        fi
    fi

    read -rp "  OS variant   : " vm_os

    info "Creating VM '$vm_name'..."
    virt-install \
        --name "$vm_name" \
        --vcpus "$vm_vcpus" \
        --memory "$vm_ram" \
        --disk "$vm_disk_arg" \
        --cdrom "$vm_iso" \
        --os-variant "$vm_os" \
        --graphics spice \
        --noautoconsole \
        --boot cdrom,hd

    info "Path defaults used: images=$KVM_IMAGES_DIR snaps=$KVM_SNAPS_DIR exports=$KVM_EXPORTS_DIR"
}

# ─── VM Deletion ──────────────────────────────────────────────────────────────
cmd_delete() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm delete <vm-name>"; exit 1; }
    warn "This will UNDEFINE and remove storage for '$vm'."
    read -rp "  Type the VM name to confirm: " confirm
    [[ "$confirm" != "$vm" ]] && { err "Aborted."; exit 1; }
    virsh destroy "$vm" 2>/dev/null || true
    virsh undefine "$vm" --remove-all-storage
    info "VM '$vm' deleted."
}

# ─── Console / GUI ────────────────────────────────────────────────────────────
cmd_console() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm console <vm-name>"; exit 1; }
    info "Connecting to serial console of $vm (Ctrl+] to exit)..."
    virsh console "$vm"
}

cmd_gui() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm gui <vm-name>"; exit 1; }
    require virt-viewer
    virt-viewer --connect qemu:///system "$vm" &
}

# ─── Network ──────────────────────────────────────────────────────────────────
cmd_net_list() {
    header "Networks"
    virsh net-list --all
}

cmd_net_start() {
    local net="${1:-}"
    [[ -z "$net" ]] && { err "Usage: lazykvm net-start <network>"; exit 1; }
    virsh net-start "$net"
}

cmd_net_stop() {
    local net="${1:-}"
    [[ -z "$net" ]] && { err "Usage: lazykvm net-stop <network>"; exit 1; }
    virsh net-destroy "$net"
}

cmd_ip() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm ip <vm-name>"; exit 1; }
    header "IP addresses: $vm"
    virsh domifaddr "$vm" 2>/dev/null || warn "VM may be off or agent not running."
}

# ─── Storage ──────────────────────────────────────────────────────────────────
cmd_pool_list() {
    header "Storage Pools"
    virsh pool-list --all
}

cmd_vol_list() {
    local pool="${1:-$POOL_IMAGES_NAME}"
    header "Volumes in pool: $pool"
    virsh vol-list "$pool"
}

# ─── Auto-start ───────────────────────────────────────────────────────────────
cmd_autostart_on() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm autostart-on <vm-name>"; exit 1; }
    virsh autostart "$vm"
    info "Autostart enabled for $vm."
}

cmd_autostart_off() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm autostart-off <vm-name>"; exit 1; }
    virsh autostart --disable "$vm"
    info "Autostart disabled for $vm."
}

# ─── Host Info ────────────────────────────────────────────────────────────────
cmd_host() {
    header "Host capabilities"
    virsh nodeinfo
    echo
    header "CPU model"
    virsh nodecpumap
}

# ─── XML Dump / Edit ──────────────────────────────────────────────────────────
cmd_xml() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm xml <vm-name>"; exit 1; }
    virsh dumpxml "$vm"
}

cmd_edit() {
    local vm="${1:-}"
    [[ -z "$vm" ]] && { err "Usage: lazykvm edit <vm-name>"; exit 1; }
    virsh edit "$vm"
}

# ─── Interactive Menu ─────────────────────────────────────────────────────────
interactive_menu() {
    while true; do
        header "KVM Manager"
        echo -e "  ${CYAN}VM Lifecycle${RESET}"
        echo "   1) List all VMs          2) List running VMs"
        echo "   3) Start                 4) Graceful stop"
        echo "   5) Force kill            6) Reboot"
        echo "   7) Pause / Suspend       8) Resume"
        echo -e "  ${CYAN}Info & Stats${RESET}"
        echo "   9) VM info              10) Live stats"
        echo "  11) Get VM IP"
        echo -e "  ${CYAN}Snapshots${RESET}"
        echo "  12) List snapshots       13) Create snapshot"
        echo "  14) Revert snapshot      15) Delete snapshot"
        echo -e "  ${CYAN}Management${RESET}"
        echo "  16) Clone VM             17) Create new VM"
        echo "  18) Delete VM"
        echo -e "  ${CYAN}Console / GUI${RESET}"
        echo "  19) Serial console       20) Graphical viewer"
        echo -e "  ${CYAN}Networking${RESET}"
        echo "  21) List networks        22) Start network"
        echo "  23) Stop network"
        echo -e "  ${CYAN}Storage${RESET}"
        echo "  24) List pools           25) List volumes"
        echo -e "  ${CYAN}Config${RESET}"
        echo "  26) Dump XML             27) Edit XML"
        echo "  28) Autostart ON         29) Autostart OFF"
        echo "  30) Host info            31) Init KVM folders"
        echo "   q) Quit"
        echo
        read -rp "  Choice: " choice

        case "$choice" in
            1)  cmd_list ;;
            2)  cmd_running ;;
            3)  read -rp "  VM name: " v; cmd_start "$v" ;;
            4)  read -rp "  VM name: " v; cmd_stop "$v" ;;
            5)  read -rp "  VM name: " v; cmd_kill "$v" ;;
            6)  read -rp "  VM name: " v; cmd_reboot "$v" ;;
            7)  read -rp "  VM name: " v; cmd_pause "$v" ;;
            8)  read -rp "  VM name: " v; cmd_resume "$v" ;;
            9)  read -rp "  VM name: " v; cmd_info "$v" ;;
            10) read -rp "  VM name: " v; cmd_stats "$v" ;;
            11) read -rp "  VM name: " v; cmd_ip "$v" ;;
            12) read -rp "  VM name: " v; cmd_snap_list "$v" ;;
            13) read -rp "  VM name: " v; read -rp "  Snap name: " s; cmd_snap_create "$v" "$s" ;;
            14) read -rp "  VM name: " v; read -rp "  Snap name: " s; cmd_snap_revert "$v" "$s" ;;
            15) read -rp "  VM name: " v; read -rp "  Snap name: " s; cmd_snap_delete "$v" "$s" ;;
            16) read -rp "  Source VM: " s; read -rp "  New VM name: " d; cmd_clone "$s" "$d" ;;
            17) cmd_create ;;
            18) read -rp "  VM name: " v; cmd_delete "$v" ;;
            19) read -rp "  VM name: " v; cmd_console "$v" ;;
            20) read -rp "  VM name: " v; cmd_gui "$v" ;;
            21) cmd_net_list ;;
            22) read -rp "  Network: " n; cmd_net_start "$n" ;;
            23) read -rp "  Network: " n; cmd_net_stop "$n" ;;
            24) cmd_pool_list ;;
            25) read -rp "  Pool [$POOL_IMAGES_NAME]: " p; cmd_vol_list "${p:-$POOL_IMAGES_NAME}" ;;
            26) read -rp "  VM name: " v; cmd_xml "$v" ;;
            27) read -rp "  VM name: " v; cmd_edit "$v" ;;
            28) read -rp "  VM name: " v; cmd_autostart_on "$v" ;;
            29) read -rp "  VM name: " v; cmd_autostart_off "$v" ;;
            30) cmd_host ;;
            31) cmd_init ;;
            q|Q) echo "Bye."; exit 0 ;;
            *) warn "Unknown choice: $choice" ;;
        esac

        echo
        read -rp "  Press Enter to continue..." _
    done
}

# ─── Help ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}lazykvm${RESET} — QEMU/KVM manager

${CYAN}Usage:${RESET} lazykvm [command] [args]
    lazykvm            (launch interactive menu)

${CYAN}Commands:${RESET}
    list                    List all VMs
    running                 List running VMs
    start   <vm>            Start a VM
    stop    <vm>            Graceful shutdown
    kill    <vm>            Force destroy
    reboot  <vm>            Reboot a VM
    pause   <vm>            Suspend a VM
    resume  <vm>            Resume a VM
    info    <vm>            Detailed VM info
    stats   <vm>            Live domain stats
    ip      <vm>            Get VM IP address
    console <vm>            Attach serial console
    gui     <vm>            Open graphical viewer (virt-viewer)
    xml     <vm>            Dump domain XML
    edit    <vm>            Edit domain XML
    create                  Create a new VM (interactive)
    clone   <src> <dst>     Clone a VM
    delete  <vm>            Undefine + remove storage
    autostart-on  <vm>      Enable autostart
    autostart-off <vm>      Disable autostart
    snap-list   <vm>        List snapshots
    snap-create <vm> <name> Create a snapshot
    snap-revert <vm> <name> Revert to snapshot
    snap-delete <vm> <name> Delete a snapshot
    net-list                List networks
    net-start <net>         Start a network
    net-stop  <net>         Stop a network
    pool-list               List storage pools
    vol-list  [pool]        List volumes in pool (default: $POOL_IMAGES_NAME)
    host                    Show host node info
    init                    Create ~/KVM/{iso,images,snaps,exports,nets} + define pools
EOF
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
case "${1:-}" in
    "")             interactive_menu ;;
    list)           cmd_list ;;
    running)        cmd_running ;;
    start)          cmd_start "${2:-}" ;;
    stop)           cmd_stop "${2:-}" ;;
    kill)           cmd_kill "${2:-}" ;;
    reboot)         cmd_reboot "${2:-}" ;;
    pause)          cmd_pause "${2:-}" ;;
    resume)         cmd_resume "${2:-}" ;;
    info)           cmd_info "${2:-}" ;;
    stats)          cmd_stats "${2:-}" ;;
    ip)             cmd_ip "${2:-}" ;;
    console)        cmd_console "${2:-}" ;;
    gui)            cmd_gui "${2:-}" ;;
    xml)            cmd_xml "${2:-}" ;;
    edit)           cmd_edit "${2:-}" ;;
    create)         cmd_create ;;
    clone)          cmd_clone "${2:-}" "${3:-}" ;;
    delete)         cmd_delete "${2:-}" ;;
    autostart-on)   cmd_autostart_on "${2:-}" ;;
    autostart-off)  cmd_autostart_off "${2:-}" ;;
    snap-list)      cmd_snap_list "${2:-}" ;;
    snap-create)    cmd_snap_create "${2:-}" "${3:-}" ;;
    snap-revert)    cmd_snap_revert "${2:-}" "${3:-}" ;;
    snap-delete)    cmd_snap_delete "${2:-}" "${3:-}" ;;
    net-list)       cmd_net_list ;;
    net-start)      cmd_net_start "${2:-}" ;;
    net-stop)       cmd_net_stop "${2:-}" ;;
    pool-list)      cmd_pool_list ;;
    vol-list)       cmd_vol_list "${2:-$POOL_IMAGES_NAME}" ;;
    host)           cmd_host ;;
    init)           cmd_init ;;
    help|-h|--help) usage ;;
    *)              err "Unknown command: $1"; usage; exit 1 ;;
esac
