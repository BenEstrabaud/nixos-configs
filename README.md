# nixos-config

Single-node NAS running NixOS with k3s and a full monitoring stack
(Prometheus, Grafana, Thanos, smartctl-exporter).

## Hardware

| Component | Detail |
|---|---|
| CPU | Intel (x86_64, VT-x) |
| Boot | USB stick (GRUB MBR + `/boot` ext4) |
| Root | M.2 128 GB NVMe partition 1 (~96 GiB XFS `/`) |
| Cache | M.2 NVMe partition 2 (remainder, dm-writecache for data array) |
| Data | 6 x 4 TB SATA in mdadm RAID6 -> LVM -> XFS `/data` |

## Architecture

### Storage stack

```
6 x 4 TB SATA
      |
 mdadm RAID6 (/dev/md/nas)          M.2 NVMe p2
      |                                   |
      +------- LVM VG "nas" -------------+
      |                                   |
   LV "data"  <--- dm-writecache ---  LV "cache"
      |
   XFS /data
      |
   /data/kubernetes (k3s local-path-provisioner)
```

### Monitoring

| Component | Role |
|---|---|
| kube-prometheus-stack | Prometheus + Grafana + default dashboards/alerts |
| Thanos | Long-term metric storage |
| smartctl-exporter | SMART disk metrics from inside k8s |
| smartd | Host-level SMART monitoring (independent of k8s) |
| pvc-alerts | PrometheusRule for PVC usage alerts |

### Services

- **k3s** — single-node Kubernetes (bundles containerd, flannel, CoreDNS, local-path-provisioner)
- **OpenSSH** — key-only auth, no root login
- **firewall** — ports 22 (SSH), 6443 (k3s API), 30030 (Grafana NodePort)

## Repository layout

```
.
├── flake.nix                      # Flake: NixOS config + test checks
├── hosts/
│   └── nas/
│       ├── default.nix            # Boot + storage (GRUB, mdadm, dm-writecache)
│       ├── hardware-configuration.nix  # Filesystems, kernel modules, disk layout
│       └── services.nix           # Networking, SSH, users, k3s, monitoring, packages
├── manifests/
│   ├── monitoring-ns.yaml         # monitoring namespace
│   ├── kube-prometheus-stack.yaml # Helm chart (Prometheus + Grafana)
│   ├── thanos.yaml                # Helm chart
│   ├── pvc-alerts.yaml            # PrometheusRule
│   └── smartctl-exporter.yaml     # Helm chart
├── tests/
│   └── nas.nix                    # NixOS VM integration test
└── run-tests.sh                   # Test runner (native nix / Docker fallback)
```

## Deploying to the NAS

Follow the installation steps in `hosts/nas/hardware-configuration.nix`, then:

```bash
nixos-install --flake /path/to/nixos-config#nas
```

After first boot, replace the `REPLACE-*` placeholders with real UUIDs from `blkid`.

For subsequent changes:

```bash
nixos-rebuild switch --flake /path/to/nixos-config#nas
```

## Tests

The NixOS VM test (`tests/nas.nix`) validates 12 assertion groups:

1. USB boot stick partitioning + GRUB install
2. RAID6 array creation (6 drives)
3. LVM + dm-writecache setup
4. XFS formatting + mount on `/data`
5. SSH hardening (key-only, no root login)
6. User `ben` exists and is in `wheel`
7. Firewall rules (ports 22, 6443, 30030)
8. k3s starts and node reaches Ready
9. Monitoring manifest symlinks present
10. Required packages installed
11. kube-system + monitoring pods healthy
12. PVC allocation + write test on `/data/kubernetes`

The test VM needs internet access to pull container images (k3s, monitoring
stack). The nix build sandbox blocks outbound network, so the Docker path
passes `sandbox = false` in nix.conf. The test adds a QEMU SLIRP NIC on a
dedicated subnet (10.0.10.0/24) for NAT internet access — see `tests/nas.nix`
for details.

## Development setup

### Linux with nix (recommended)

The fastest way to run tests. QEMU uses KVM for hardware-accelerated
virtualisation, so the test VM runs at near-native speed.

1. [Install nix](https://nixos.org/download/) if you haven't already.

2. Ensure your user can access `/dev/kvm`:

   ```
   ls -l /dev/kvm
   ```

   If you get "permission denied", add yourself to the `kvm` group:

   ```
   sudo usermod -aG kvm "$USER"
   ```

   Then log out and back in.

3. Run the tests:

   ```
   ./run-tests.sh
   ```

No builder VM or special configuration is needed — nix builds and runs
the NixOS test VM directly on the host.

### Docker (macOS or Linux without nix)

Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
(macOS) or Docker Engine (Linux), then:

```bash
./run-tests.sh
```

The script runs the build inside a `nixos/nix` container with `--privileged`.
On Linux hosts with `/dev/kvm`, the test VM gets KVM acceleration inside the
container. On macOS (Docker Desktop), there is no KVM — QEMU falls back to
software emulation (~20+ minutes).

## Placeholder checklist

Before deploying to real hardware, replace these placeholders:

- [ ] `hosts/nas/default.nix` — `REPLACE-WITH-USB-STICK-ID` (GRUB device)
- [ ] `hosts/nas/hardware-configuration.nix` — `REPLACE-ROOT-UUID` (M.2 root partition)
- [ ] `hosts/nas/hardware-configuration.nix` — `REPLACE-BOOT-UUID` (USB boot partition)
- [ ] `hosts/nas/services.nix` — SSH authorized key for user `ben`
