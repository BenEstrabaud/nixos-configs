{ lib, ... }:

let
  diskDir = "/tmp/nas-test-disks";
in
{
  name = "nas";

  nodes.nas = { pkgs, lib, ... }: {
    imports = [ ../hosts/nas/services.nix ];

    # -- VM resources (match production hardware) --
    virtualisation.cores = 4;
    virtualisation.memorySize = 8192;
    virtualisation.diskSize = 20480;

    # -- Realistic device emulation --
    # The real NAS uses a USB boot stick, 6 SATA drives (AHCI), and an NVMe
    # cache drive. Emulate these device types instead of virtio so the test
    # exercises the correct kernel modules and device paths.
    # Disk images are created as sparse files before nas.start() in testScript.
    # vda (virtio) remains the test framework's root disk.
    boot.initrd.availableKernelModules = [
      "ahci" "nvme" "xhci_pci" "usb_storage" "sd_mod"
    ];

    # -- Storage kernel modules (from default.nix + hardware-configuration.nix) --
    boot.swraid.enable = true;
    boot.kernelModules = [ "dm_writecache" "raid456" ];

    # -- GRUB + partitioning tools (not in services.nix) --
    environment.systemPackages = with pkgs; [ grub2 parted curl ];

    # -- Internet access for container image pulls --
    # The test framework's default SLIRP NIC (eth0, 10.0.2.x) provides NAT.
    # DHCP supplies the default gateway; we just pin DNS to SLIRP's forwarder.
    # Requires `--option sandbox false` when building (see run-tests.sh).
    networking.nameservers = [ "10.0.2.3" ];

    virtualisation.qemu.options = [
      # USB boot stick (256 MB) — guest sees /dev/disk/by-id/usb-*USB-BOOT*
      "-drive file=${diskDir}/usb.raw,if=none,id=usbdrive,format=raw"
      "-device nec-usb-xhci,id=xhci"
      "-device usb-storage,bus=xhci.0,drive=usbdrive,serial=USB-BOOT"

      # 6x SATA data drives (2048 MB each) via AHCI
      # Guest sees /dev/disk/by-id/ata-*SATA-DATA-{1..6}*
      "-drive file=${diskDir}/sata0.raw,if=none,id=sata0,format=raw"
      "-drive file=${diskDir}/sata1.raw,if=none,id=sata1,format=raw"
      "-drive file=${diskDir}/sata2.raw,if=none,id=sata2,format=raw"
      "-drive file=${diskDir}/sata3.raw,if=none,id=sata3,format=raw"
      "-drive file=${diskDir}/sata4.raw,if=none,id=sata4,format=raw"
      "-drive file=${diskDir}/sata5.raw,if=none,id=sata5,format=raw"
      "-device ich9-ahci,id=ahci"
      "-device ide-hd,drive=sata0,bus=ahci.0,serial=SATA-DATA-1"
      "-device ide-hd,drive=sata1,bus=ahci.1,serial=SATA-DATA-2"
      "-device ide-hd,drive=sata2,bus=ahci.2,serial=SATA-DATA-3"
      "-device ide-hd,drive=sata3,bus=ahci.3,serial=SATA-DATA-4"
      "-device ide-hd,drive=sata4,bus=ahci.4,serial=SATA-DATA-5"
      "-device ide-hd,drive=sata5,bus=ahci.5,serial=SATA-DATA-6"

      # NVMe cache drive (1024 MB) — guest sees /dev/nvme0n1
      "-drive file=${diskDir}/nvme.raw,if=none,id=nvme0,format=raw"
      "-device nvme,drive=nvme0,serial=NVME-CACHE"

      # Debug shell — connect with: socat - UNIX-CONNECT:/tmp/nas-shell.sock
      # Use an explicit chardev+device pair to avoid interfering with the
      # framework's `-serial stdio` (which claims ttyS0 for console logs).
      "-chardev" "socket,id=debugshell,path=/tmp/nas-shell.sock,server=on,wait=off"
      "-device" "isa-serial,chardev=debugshell"
    ];

    # -- Debug: auto-login root shell on ttyS1 --
    # socat - UNIX-CONNECT:/tmp/nas-shell.sock
    systemd.services."serial-getty@ttyS1" = {
      enable = true;
      wantedBy = [ "multi-user.target" ];
    };
    services.getty.autologinUser = "root";

    # -- VM overrides --
    # No real SMART-capable drives in the VM.
    services.smartd.enable = lib.mkForce false;
  };

  testScript = ''
    import os

    # Create sparse disk images before starting the VM.
    # sandbox=false (see run-tests.sh) allows /tmp access.
    os.makedirs("${diskDir}", exist_ok=True)
    for name, size_mb in [("usb", 256), ("nvme", 1024)] + [(f"sata{i}", 2048) for i in range(6)]:
        path = f"${diskDir}/{name}.raw"
        with open(path, "wb") as f:
            f.truncate(size_mb * 1024 * 1024)

    nas.start()
    nas.wait_for_unit("multi-user.target", timeout=180)

    # ========== Internet connectivity (SLIRP NIC) ==========

    # Wait for the framework SLIRP NIC to get a DHCP lease (10.0.2.x subnet)
    nas.wait_until_succeeds(
        "ip addr show | grep -q '10\\.0\\.2\\.'",
        timeout=60,
    )
    # Log network state for debugging
    nas.succeed("ip addr show >&2")
    nas.succeed("ip route show >&2")
    nas.succeed("cat /etc/resolv.conf >&2")
    # Verify DNS resolution works (needed for container image pulls)
    nas.wait_until_succeeds(
        "getent hosts registry-1.docker.io",
        timeout=120,
    )

    # ========== Device discovery ==========
    # Discover devices by serial via /dev/disk/by-id/, matching real deployment.

    # Log device state for debugging
    nas.succeed("ls -la /dev/disk/by-id/ >&2")
    nas.succeed("lsblk >&2")

    # USB boot stick (serial: USB-BOOT)
    usb_dev = nas.succeed(
        "readlink -f $(ls /dev/disk/by-id/usb-*USB-BOOT* | grep -v part | head -1)"
    ).strip()

    # 6x SATA data drives (serials: SATA-DATA-1 through SATA-DATA-6)
    sata_devs = []
    for i in range(1, 7):
        dev = nas.succeed(
            f"readlink -f $(ls /dev/disk/by-id/ata-*SATA-DATA-{i}* | grep -v part | head -1)"
        ).strip()
        sata_devs.append(dev)

    # NVMe cache drive (unambiguous — only NVMe device in the VM)
    nvme_dev = "/dev/nvme0n1"
    nas.succeed(f"test -b {nvme_dev}")

    # ========== USB boot stick: partition + GRUB ==========

    nas.succeed(f"parted {usb_dev} -- mklabel msdos")
    nas.succeed(f"parted {usb_dev} -- mkpart primary ext4 1MiB 100%")
    nas.succeed("udevadm settle")
    nas.succeed(f"mkfs.ext4 -L boot {usb_dev}1")
    nas.succeed("mkdir -p /boot")
    nas.succeed(f"mount {usb_dev}1 /boot")
    nas.succeed(f"grub-install --target=i386-pc --boot-directory=/boot {usb_dev}")
    nas.succeed("test -d /boot/grub")

    # ========== Storage: RAID6 + LVM + dm-writecache + XFS ==========

    nas.succeed("modprobe dm_writecache")

    # RAID6 from 6 SATA drives (discovered via /dev/disk/by-id/)
    raid_devs = " ".join(sata_devs)
    nas.succeed(
        f"mdadm --create /dev/md/nas --level=6 --raid-devices=6 "
        f"--metadata=1.2 --run {raid_devs}"
    )
    # Wait for udev to create the /dev/md/nas symlink (slow in nested VMs)
    nas.succeed("udevadm settle")

    raid_detail = nas.succeed("mdadm --detail /dev/md/nas")
    assert "raid6" in raid_detail.lower(), f"Expected RAID6, got:\n{raid_detail}"

    # LVM: PV on RAID array + PV on NVMe cache drive
    nas.succeed("pvcreate /dev/md/nas")
    nas.succeed(f"pvcreate {nvme_dev}")

    # VG spanning both
    nas.succeed(f"vgcreate nas /dev/md/nas {nvme_dev}")

    # Data LV on RAID, cache LV on NVMe
    nas.succeed("lvcreate -l 100%PVS -n data nas /dev/md/nas")
    nas.succeed(f"lvcreate -l 100%PVS -n cache nas {nvme_dev}")

    # Verify dm-writecache target is available before converting
    nas.succeed("dmsetup targets | grep writecache")

    # Deactivate cache LV — lvconvert requires it to be inactive
    nas.succeed("lvchange -an nas/cache")

    # Attach dm-writecache
    nas.succeed("lvconvert --type writecache --cachevol cache nas/data --yes")

    seg_type = nas.succeed("lvs -o seg_type --noheadings nas/data").strip()
    assert seg_type == "writecache", f"Expected writecache segment type, got: {seg_type}"

    # Format and mount
    nas.succeed("mkfs.xfs /dev/nas/data")
    nas.succeed("mkdir -p /data")
    nas.succeed("mount /dev/nas/data /data")
    nas.succeed("mkdir -p /data/kubernetes")

    mount_fstype = nas.succeed("findmnt -n -o FSTYPE /data").strip()
    assert mount_fstype == "xfs", f"Expected xfs on /data, got: {mount_fstype}"

    # ========== SSH ==========

    nas.wait_for_unit("sshd.service")
    sshd_config = nas.succeed("cat /etc/ssh/sshd_config")
    assert "PasswordAuthentication no" in sshd_config, "PasswordAuthentication should be disabled"
    assert "PermitRootLogin no" in sshd_config, "PermitRootLogin should be no"

    # ========== User ==========

    nas.succeed("id ben")
    groups = nas.succeed("groups ben")
    assert "wheel" in groups, f"ben should be in wheel group, got: {groups}"

    # ========== Firewall ==========

    nas.wait_for_unit("firewall.service")
    iptables = nas.succeed("iptables -L nixos-fw -n")
    for port in ["22", "6443"]:
        assert port in iptables, f"Port {port} should be open in firewall"

    # ========== k3s ==========

    nas.wait_for_unit("k3s.service", timeout=600)
    nas.wait_until_succeeds(
        "k3s kubectl get nodes | grep -w Ready",
        timeout=300,
    )

    # ========== Manifest symlinks ==========

    manifests = [
        "monitoring-ns.yaml",
        "kube-prometheus-stack.yaml",
        "thanos.yaml",
        "pvc-alerts.yaml",
        "smartctl-exporter.yaml",
        "netpol-monitoring.yaml",
        "netpol-samba.yaml",
        "metallb.yaml",
        "metallb-config.yaml",
        "samba-ns.yaml",
        "samba-operator.yaml",
        "samba-share.yaml",
        "timemachine-users-secret.yaml",
        "storage-users-secret.yaml",
        "samba-storage.yaml",
        "smbmetrics.yaml",
        "samba-dashboard.yaml",
    ]
    for m in manifests:
        path = f"/var/lib/rancher/k3s/server/manifests/{m}"
        nas.succeed(f"test -s {path}")

    # ========== Packages ==========

    for cmd in ["vim", "htop", "git", "xfs_repair", "smartctl", "sensors", "curl"]:
        nas.succeed(f"command -v {cmd}")

    # ========== Bash completion ==========

    # bash-completion package must be present (programs.bash.enableCompletion = true)
    nas.succeed("test -d /run/current-system/sw/share/bash-completion")

    # kubectl alias + completion sourced via interactiveShellInit
    nas.succeed("bash -i -c 'type kubectl' 2>/dev/null | grep -q alias")
    nas.succeed("bash -i -c 'complete -p kubectl' 2>/dev/null | grep -q __start_kubectl")

    # ========== kube-system pods healthy ==========

    nas.wait_until_succeeds(
        "k3s kubectl get pods -n kube-system --no-headers | grep -q . && "
        "k3s kubectl wait --for=condition=Ready pods --all -n kube-system "
        "--field-selector=status.phase!=Succeeded --timeout=10s",
        timeout=300,
    )

    # ========== Monitoring stack ==========

    # Wait for monitoring namespace to be created
    nas.wait_until_succeeds(
        "k3s kubectl get namespace monitoring",
        timeout=180,
    )

    # Wait for pods to appear (Helm charts need to download first)
    nas.wait_until_succeeds(
        "k3s kubectl get pods -n monitoring --no-headers 2>/dev/null | grep -q .",
        timeout=600,
    )

    # Wait for ALL monitoring pods to become Ready
    nas.wait_until_succeeds(
        "k3s kubectl get pods -n monitoring --no-headers | grep -q . && "
        "k3s kubectl wait --for=condition=Ready pods --all -n monitoring "
        "--field-selector=status.phase!=Succeeded --timeout=10s",
        timeout=900,
    )

    # ========== Grafana health check ==========

    grafana_ip = nas.wait_until_succeeds(
        "k3s kubectl get svc -n monitoring kube-prometheus-stack-grafana "
        "-o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -E '[0-9]'",
        timeout=120,
    ).strip()
    nas.wait_until_succeeds(
        f"curl -sf http://{grafana_ip}/api/health",
        timeout=120,
    )

    # ========== PVC allocation + write test ==========

    nas.succeed(
        "cat > /tmp/test-pvc.yaml << 'YAML'\n"
        "apiVersion: v1\n"
        "kind: PersistentVolumeClaim\n"
        "metadata:\n"
        "  name: test-pvc\n"
        "spec:\n"
        "  accessModes: [ReadWriteOnce]\n"
        "  resources:\n"
        "    requests:\n"
        "      storage: 64Mi\n"
        "---\n"
        "apiVersion: v1\n"
        "kind: Pod\n"
        "metadata:\n"
        "  name: test-pvc-writer\n"
        "spec:\n"
        "  containers:\n"
        "  - name: writer\n"
        "    image: busybox:1\n"
        "    command: ['sh', '-c', 'echo pvc-test-ok > /data/test-file && sleep 3600']\n"
        "    volumeMounts:\n"
        "    - name: data\n"
        "      mountPath: /data\n"
        "  volumes:\n"
        "  - name: data\n"
        "    persistentVolumeClaim:\n"
        "      claimName: test-pvc\n"
        "YAML"
    )
    nas.succeed("k3s kubectl apply -f /tmp/test-pvc.yaml")

    # Wait for pod to be Running
    nas.wait_until_succeeds(
        "k3s kubectl get pod test-pvc-writer -o jsonpath='{.status.phase}' | grep -q Running",
        timeout=300,
    )

    # Verify data via kubectl exec
    nas.succeed("k3s kubectl exec test-pvc-writer -- cat /data/test-file | grep -q pvc-test-ok")

    # Verify backing storage on host filesystem
    nas.succeed("find /data/kubernetes -name test-file -exec cat {} \\; | grep -q pvc-test-ok")
  '';
}
