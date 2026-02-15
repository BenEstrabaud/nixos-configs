{ config, pkgs, ... }:

{
  imports = [
    ./services.nix
    ./hardware-configuration.nix
  ];

  # ---------- Boot ----------
  # GRUB on USB stick — the BIOS cannot detect the PCIe-riser M.2.
  # Find the stable device path with: ls -l /dev/disk/by-id/usb-*
  boot.loader.grub = {
    enable = true;
    device = "/dev/disk/by-id/REPLACE-WITH-USB-STICK-ID";
  };

  # ---------- Storage ----------
  boot.swraid.enable = true; # mdadm RAID6 assembly

  boot.initrd.kernelModules = [ "dm_writecache" ];
}
