# lazykvm

Single-file QEMU/KVM manager written in Bash.

lazykvm provides an interactive menu and direct commands for VM lifecycle, snapshots, pools, networks, and host/domain operations.

## Features

- Single script workflow: lazykvm.sh
- Interactive menu mode and command mode
- VM lifecycle: start, stop, kill, reboot, pause, resume
- VM inspection: info, stats, ip, xml, edit
- Snapshot operations: list, create, revert, delete
- Storage management with default KVM directory pools
- Initialization flow that can create pools and configure libvirt daemon behavior
- Automatic daemon check/start on run when start-only policy is selected

## Default KVM Layout

The init command prepares:

- ~/KVM/iso
- ~/KVM/images
- ~/KVM/snaps
- ~/KVM/exports
- ~/KVM/nets

And maps pools:

- kvm-iso -> ~/KVM/iso
- kvm-images -> ~/KVM/images
- kvm-snaps -> ~/KVM/snaps
- kvm-exports -> ~/KVM/exports

## Requirements

- Bash 4+
- libvirt / virsh
- systemd (optional, for daemon management in init)
- Optional tools for some commands:
  - virt-install
  - virt-clone
  - virt-viewer

## Quick Start

1. Make executable:

   chmod +x lazykvm.sh

2. Initialize folders/pools:

   ./lazykvm.sh init

3. Run interactive mode:

   ./lazykvm.sh

4. Or run direct commands:

   ./lazykvm.sh list
   ./lazykvm.sh create
   ./lazykvm.sh pool-list

## Command Summary

- list, running
- start <vm>, stop <vm>, kill <vm>, reboot <vm>, pause <vm>, resume <vm>
- info <vm>, stats <vm>, ip <vm>
- console <vm>, gui <vm>
- xml <vm>, edit <vm>
- create, clone <src> <dst>, delete <vm>
- autostart-on <vm>, autostart-off <vm>
- snap-list <vm>, snap-create <vm> <name>, snap-revert <vm> <name>, snap-delete <vm> <name>
- net-list, net-start <net>, net-stop <net>
- pool-list, vol-list [pool]
- host
- init

## Notes

- If daemon policy is set to start-only during init, lazykvm will check libvirt service status on every run and start it if needed.
- If permissions block daemon or pool operations, rerun with appropriate privileges or use sudo for systemctl/libvirt setup commands.

## License

MIT. See LICENSE.
