{ lib, ... }:

{
  name = "nas";

  nodes.nas = { pkgs, lib, ... }: {
    imports = [ ../hosts/nas/services.nix ];

    # -- VM resources --
    virtualisation.memorySize = 8192;

    # Disk layout (vda is the test framework root disk):
    #   vdb         256 MB  USB stick (GRUB + /boot)
    #   vdc–vdh   6×2048 MB  RAID6 data drives
    #   vdi        1024 MB  NVMe cache partition stand-in
    virtualisation.emptyDiskImages = [ 256 2048 2048 2048 2048 2048 2048 1024 ];

    # -- Storage kernel modules (from default.nix + hardware-configuration.nix) --
    boot.swraid.enable = true;
    boot.kernelModules = [ "dm_writecache" "raid456" ];

    # -- GRUB + partitioning tools (not in services.nix) --
    environment.systemPackages = with pkgs; [ grub2 parted curl ];

    # -- Internet access for container image pulls --
    # The test framework only provides an isolated VDE network (no internet).
    # Add a QEMU user-mode (SLIRP) NIC on a dedicated subnet for NAT internet.
    # Requires `--option sandbox false` when building (see run-tests.sh).
    virtualisation.qemu.options = [
      "-netdev user,id=inet,net=10.0.10.0/24,dhcpstart=10.0.10.15"
      "-device virtio-net-pci,netdev=inet"
    ];
    networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

    # -- VM overrides --
    # No real SMART-capable drives in the VM.
    services.smartd.enable = lib.mkForce false;
  };

  testScript = ''
    nas.start()
    nas.wait_for_unit("multi-user.target", timeout=180)

    # ========== Internet connectivity (SLIRP NIC) ==========

    # Wait for the SLIRP interface to get a DHCP lease (10.0.10.x subnet)
    nas.wait_until_succeeds(
        "ip addr show | grep -q '10\\.0\\.10\\.'",
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

    # ========== USB boot stick: partition + GRUB ==========

    nas.succeed("parted /dev/vdb -- mklabel msdos")
    nas.succeed("parted /dev/vdb -- mkpart primary ext4 1MiB 100%")
    nas.succeed("udevadm settle")
    nas.succeed("mkfs.ext4 -L boot /dev/vdb1")
    nas.succeed("mkdir -p /boot")
    nas.succeed("mount /dev/vdb1 /boot")
    nas.succeed("grub-install --target=i386-pc --boot-directory=/boot /dev/vdb")
    nas.succeed("test -d /boot/grub")

    # ========== Storage: RAID6 + LVM + dm-writecache + XFS ==========

    nas.succeed("modprobe dm_writecache")

    # RAID6 from 6 virtual drives (vdc–vdh)
    nas.succeed(
        "mdadm --create /dev/md/nas --level=6 --raid-devices=6 "
        "--metadata=1.2 --run "
        "/dev/vdc /dev/vdd /dev/vde /dev/vdf /dev/vdg /dev/vdh"
    )
    # Wait for udev to create the /dev/md/nas symlink (slow in nested VMs)
    nas.succeed("udevadm settle")

    raid_detail = nas.succeed("mdadm --detail /dev/md/nas")
    assert "raid6" in raid_detail.lower(), f"Expected RAID6, got:\n{raid_detail}"

    # LVM: PV on RAID array + PV on cache drive
    nas.succeed("pvcreate /dev/md/nas")
    nas.succeed("pvcreate /dev/vdi")

    # VG spanning both
    nas.succeed("vgcreate nas /dev/md/nas /dev/vdi")

    # Data LV on RAID, cache LV on the "NVMe" drive
    nas.succeed("lvcreate -l 100%PVS -n data nas /dev/md/nas")
    nas.succeed("lvcreate -l 100%PVS -n cache nas /dev/vdi")

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
    for port in ["22", "6443", "30030"]:
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
    ]
    for m in manifests:
        path = f"/var/lib/rancher/k3s/server/manifests/{m}"
        nas.succeed(f"test -s {path}")

    # ========== Packages ==========

    for cmd in ["vim", "htop", "git", "xfs_repair", "smartctl", "sensors", "curl"]:
        nas.succeed(f"command -v {cmd}")

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

    nas.wait_until_succeeds(
        "curl -sf http://localhost:30030/api/health",
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
