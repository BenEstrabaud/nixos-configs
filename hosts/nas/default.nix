{ config, pkgs, ... }:

{
  imports = [
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

  # ---------- Networking ----------
  networking.hostName = "nas";

  # ---------- Firewall ----------
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # SSH
      6443  # k3s API server
      30030 # Grafana NodePort
    ];
    # Trust the CNI interfaces so pod-to-pod traffic is not blocked
    trustedInterfaces = [ "cni0" "flannel.1" ];
  };

  # ---------- SSH ----------
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ---------- User ----------
  users.mutableUsers = false; # declarative-only user management

  users.users.ben = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # Paste your public key here, e.g.:
      # "ssh-ed25519 AAAAC3Nza... ben@workstation"
    ];
  };

  # Allow passwordless sudo for wheel (useful for remote admin via SSH key)
  security.sudo.wheelNeedsPassword = false;

  # ---------- k3s ----------
  services.k3s = {
    enable = true;
    role = "server";
    # Single-node cluster — no external datastore needed.
    # k3s bundles containerd, flannel, CoreDNS, and local-path-provisioner.
    # local-path-provisioner is the default StorageClass; PVCs are
    # dynamically provisioned under the path below.
    extraFlags = "--default-local-storage-path /data/kubernetes";
  };

  # Required for pod networking
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # ---------- Monitoring ----------
  # Symlink Helm manifests into the k3s auto-deploy directory.
  # k3s picks these up and installs the charts automatically.
  systemd.tmpfiles.rules = [
    "d /var/lib/rancher/k3s/server/manifests 0755 root root -"
    "L+ /var/lib/rancher/k3s/server/manifests/monitoring-ns.yaml - - - - ${./../../manifests/monitoring-ns.yaml}"
    "L+ /var/lib/rancher/k3s/server/manifests/kube-prometheus-stack.yaml - - - - ${./../../manifests/kube-prometheus-stack.yaml}"
    "L+ /var/lib/rancher/k3s/server/manifests/thanos.yaml - - - - ${./../../manifests/thanos.yaml}"
    "L+ /var/lib/rancher/k3s/server/manifests/pvc-alerts.yaml - - - - ${./../../manifests/pvc-alerts.yaml}"
    "L+ /var/lib/rancher/k3s/server/manifests/smartctl-exporter.yaml - - - - ${./../../manifests/smartctl-exporter.yaml}"
  ];

  # Host-level SMART monitoring (runs independently of k8s)
  services.smartd = {
    enable = true;
    autodetect = true;
  };

  # ---------- Packages ----------
  environment.systemPackages = with pkgs; [
    vim
    htop
    git
    k3s           # provides kubectl via `k3s kubectl`
    xfsprogs      # XFS management (xfs_repair, xfs_growfs, etc.)
    mdadm
    lvm2
    smartmontools # smartctl for manual drive inspection
    lm_sensors    # sensors for manual temp readings
  ];

  system.stateVersion = "24.11";
}
