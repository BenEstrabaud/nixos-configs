# Hardware configuration — regenerate on the live system with:
#   nixos-generate-config --show-hardware-config
# then merge the output into this file (keep the storage section below).
#
# ============================================================
# Disk layout
# ============================================================
#
#   USB stick              → /boot (ext4) + GRUB MBR
#   M.2 128 GB (nvme0n1)
#     ├─ p1  ~96 GiB      → /     (XFS)
#     └─ p2  remainder     → LVM PV  (dm-writecache for data array)
#   6 × 4 TB SATA  → mdadm RAID6  (/dev/md/nas)
#     └─ LVM PV            → VG "nas"
#         ├─ LV "data"     → /data (XFS), writecached via lv-cache
#         └─ LV "cache"    → consumed by dm-writecache
#
# ============================================================
# Installation steps (run from the NixOS live installer)
# ============================================================
#
# 1. Partition the USB stick (assuming /dev/sdX):
#      parted /dev/sdX -- mklabel msdos
#      parted /dev/sdX -- mkpart primary ext4 1MiB 100%
#      mkfs.ext4 -L boot /dev/sdX1
#
# 2. Partition the M.2 (assuming /dev/nvme0n1):
#      parted /dev/nvme0n1 -- mklabel gpt
#      parted /dev/nvme0n1 -- mkpart root xfs 1MiB 96GiB
#      parted /dev/nvme0n1 -- mkpart cache 96GiB 100%
#      mkfs.xfs -L nixos /dev/nvme0n1p1
#      # nvme0n1p2 is left raw for LVM
#
# 3. Create the RAID6 array from the 6 SATA drives:
#      # Identify drives:  ls -l /dev/disk/by-id/ata-*
#      mdadm --create /dev/md/nas --level=6 --raid-devices=6 \
#        /dev/disk/by-id/ata-DRIVE1 \
#        /dev/disk/by-id/ata-DRIVE2 \
#        /dev/disk/by-id/ata-DRIVE3 \
#        /dev/disk/by-id/ata-DRIVE4 \
#        /dev/disk/by-id/ata-DRIVE5 \
#        /dev/disk/by-id/ata-DRIVE6
#
# 4. Set up LVM + dm-writecache:
#      pvcreate /dev/md/nas
#      pvcreate /dev/nvme0n1p2
#      vgcreate nas /dev/md/nas /dev/nvme0n1p2
#      lvcreate -l 100%PVS -n data nas /dev/md/nas
#      lvcreate -l 100%PVS -n cache nas /dev/nvme0n1p2
#      lvconvert --type writecache --cachevol cache nas/data
#      mkfs.xfs -L data /dev/nas/data
#
# 5. Mount everything and install:
#      mount /dev/nvme0n1p1 /mnt
#      mkdir -p /mnt/{boot,data}
#      mount /dev/sdX1 /mnt/boot
#      mount /dev/nas/data /mnt/data
#      nixos-install --flake /path/to/nixos-config#nas
#
# 6. After first boot, replace the REPLACE-* placeholders below
#    with real UUIDs from `blkid`.
# ============================================================

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # -- Kernel / initrd modules --
  boot.initrd.availableKernelModules = [
    "xhci_pci"    # USB 3.x
    "ahci"        # SATA (the 6 data drives)
    "nvme"        # M.2 NVMe via PCIe riser
    "usbcore"     # USB stack (boot USB stick)
    "usb_storage"
    "sd_mod"
    "dm_mod"      # device-mapper core
    "raid456"     # RAID 5/6
  ];
  boot.kernelModules = [
    "kvm-intel"
    "coretemp"  # CPU temperature (hwmon, picked up by node-exporter)
    "drivetemp" # HDD temperature via SATA (hwmon, picked up by node-exporter)
  ];

  # -- Root: M.2 partition 1 (XFS, ~96 GiB) --
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/REPLACE-ROOT-UUID";
    fsType = "xfs";
  };

  # -- Boot: USB stick --
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/REPLACE-BOOT-UUID";
    fsType = "ext4";
  };

  # -- Data: mdadm RAID6 → LVM writecache → XFS --
  fileSystems."/data" = {
    device = "/dev/nas/data";
    fsType = "xfs";
  };

  hardware.cpu.intel.updateMicrocode = true;
}
