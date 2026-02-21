# nixos-config

This repo assists in the deployment and test of a **declarative** nixOS configuration on a home NAS. Since the config is declarative, the OS can be deployed almost "in one go" with the help of `nixos-install`, apart from a small setup script to run beforehand to configure storage. This means that the entire OS can be re-deployed very quickly and efficiently. A strong test framework is also present to verify that the nixOS configuration works as expected before a "real world" install takes place. Apart from nixOS and some common packages, this config deploys a k3s Kubernetes cluster with useful components: Prometheus/Grafana monitoring, long-term metric storage via Thanos, MetalLB load balancer, a Samba Time Machine share, and automatic NixOS upgrades.

## Hardware

This is the current hardware specs for which this config was built, but it can be installed on other similar configurations too.
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
| smbmetrics | Samba metrics (smbstatus) exposed to Prometheus — injected as a sidecar by the operator |
| smartd | Host-level SMART monitoring (independent of k8s) |
| pvc-alerts | PrometheusRule for PVC usage alerts |

### Services

- **k3s** — single-node Kubernetes (bundles containerd, flannel, CoreDNS, local-path-provisioner; Traefik and klipper-lb are disabled)
- **MetalLB** — L2 load balancer; assigns LAN IPs to `LoadBalancer` services from a configurable pool
- **Samba** — Time Machine share (2 Ti PVC) and general storage share (configurable PVC), managed by the samba-operator; auto-discovered on macOS via Avahi mDNS
- **Avahi** — mDNS daemon; `samba-avahi-publisher.service` watches MetalLB for assigned IPs and dynamically advertises each share (e.g. `timemachine-samba.local`) so macOS auto-discovers them without a hardcoded IP
- **OpenSSH** — key-only auth, no root login
- **firewall** — ports 22 (SSH), 6443 (k3s API); pod services (Samba, Grafana) are exposed via MetalLB and bypass the host firewall through kube-proxy DNAT (FORWARD chain, unfiltered by default)
- **auto-upgrade** — weekly `nixos-rebuild switch` that updates the `nixpkgs` flake input (and thus k3s)

### Shell

- **bash completion** — enabled system-wide via `programs.bash.enableCompletion`
- **kubectl** — aliased to `k3s kubectl`; tab-completion registered for both names

## Repository layout

```
.
├── flake.nix                      # Flake: NixOS config + test checks
├── hosts/
│   └── nas/
│       ├── default.nix            # Boot + storage (GRUB, mdadm, dm-writecache)
│       ├── hardware-configuration.nix  # Filesystems, kernel modules, disk layout
│       └── services.nix           # Networking, SSH, users, k3s, Avahi, packages, auto-upgrade
├── manifests/
│   ├── monitoring-ns.yaml         # monitoring namespace + Thanos object-store secret
│   ├── kube-prometheus-stack.yaml # Helm chart (Prometheus + Grafana + Alertmanager)
│   ├── thanos.yaml                # Helm chart (long-term metrics)
│   ├── pvc-alerts.yaml            # PrometheusRule (PVC usage warnings)
│   ├── smartctl-exporter.yaml     # Helm chart (SMART metrics DaemonSet)
│   ├── smbmetrics.yaml            # ServiceMonitor for smbmetrics (sidecar injected by operator)
│   ├── netpol-monitoring.yaml     # NetworkPolicies for the monitoring namespace
│   ├── netpol-samba.yaml          # NetworkPolicies for the samba namespace
│   ├── metallb.yaml               # Helm chart (MetalLB load balancer)
│   ├── samba-ns.yaml              # samba namespace
│   └── samba-share.yaml           # timemachine PVC + SmbCommonConfig + SmbShare
├── tests/
│   └── nas.nix                    # NixOS VM integration test
└── run-tests.sh                   # Test runner (native nix / Docker fallback)
```

> **Note:** Several manifests are generated at build time rather than stored as static files:
>
> - **`metallb-config.yaml`** (IPAddressPool + L2Advertisement) — generated from `metallbIpRange`.
>
> - **`timemachine-users-secret.yaml`** / **`storage-users-secret.yaml`** — K8s Secrets
>   containing sambacc-format user credentials. Generated from `sambaTimemachinePassword` /
>   `sambaStoragePassword` in `services.nix`. **Passwords land in `/nix/store` which is
>   world-readable on the NAS** — acceptable for a single-user home NAS.
>
> - **`samba-storage.yaml`** (PVC + SmbSecurityConfig + SmbShare for the storage share) —
>   generated from `storageShareSize` in `services.nix`.
>
> - **`samba-operator.yaml`** — the upstream v0.8 release manifest fetched from GitHub at
>   build time, with the operator container image patched to a [forked version][samba-op-fork]
>   (`ghcr.io/benestrabaud/samba-operator:v0.8-be-0`). The fork fixes a bug where the
>   smbmetrics sidecar probes used port 8080 while the binary defaulted to 9922, causing
>   CrashLoopBackOff. A [pull request][samba-op-pr] has been submitted upstream.
>
> [samba-op-fork]: https://github.com/BenEstrabaud/samba-operator/tree/fix-smbmetrics-port
> [samba-op-pr]: https://github.com/samba-in-kubernetes/samba-operator/pulls

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

## MetalLB

MetalLB runs in L2 mode and responds to ARP on the LAN for IP addresses in the
configured pool. The k3s built-in load balancer (`servicelb`) is disabled so
MetalLB is the sole `LoadBalancer` provider.

**Configure the IP range** by editing the `metallbIpRange` variable near the top
of `hosts/nas/services.nix`:

```nix
metallbIpRange = "192.168.1.200-192.168.1.250";
```

Pick a range that is:
- On the same subnet as the NAS
- Outside your router's DHCP range
- Not already assigned to any static device

After changing the value, run `nixos-rebuild switch` — the manifest is
regenerated automatically.

## Samba / Time Machine

The Samba shares are managed by a [forked samba-in-kubernetes operator][samba-op-fork]
(`ghcr.io/benestrabaud/samba-operator:v0.8-be-0`) based on upstream v0.8. The fork fixes
the smbmetrics port mismatch bug; a PR is pending upstream. The operator is injected as a
`SAMBA_OP_METRICS_EXPORTER_MODE=enabled` sidecar into each samba pod, sharing `/run` and
`/var/lib/samba` volumes so `smbstatus` can read smbd's Unix sockets and tdb databases.
Prometheus scrapes the sidecar via the ServiceMonitor in `smbmetrics.yaml`.
Two shares are created:

| Share | Purpose | PVC |
|---|---|---|
| `timemachine` | macOS Time Machine backups | 2 Ti (edit in `samba-share.yaml`) |
| `storage` | General-purpose file storage | `storageShareSize` (default 10 Ti) |

User credentials are set via Nix variables in `hosts/nas/services.nix` and
automatically deployed as K8s Secrets — no post-install `kubectl` commands needed.

> **Security note:** Passwords are embedded in the Nix store (`/nix/store` is
> world-readable on the NAS). This is acceptable for a single-user home NAS. For
> stricter environments, use a secrets manager (e.g. sops-nix, agenix).

### Post-deploy steps

**1. Set passwords** in `hosts/nas/services.nix`:

```nix
sambaTimemachinePassword = "your-timemachine-password";
sambaStoragePassword     = "your-storage-password";
```

Then rebuild: `nixos-rebuild switch --flake /etc/nixos#nas`

**2. Enable smbmetrics** (set once on the operator Deployment — persists across reconciles):

```bash
kubectl set env deployment/samba-operator-controller-manager \
  -n samba-operator-system \
  SAMBA_OP_METRICS_EXPORTER_MODE=enabled
```

Then delete the samba pods so the operator reinjects the sidecar on recreation:

```bash
kubectl delete pods -n samba -l app=samba
```

**3. Connect from macOS:**

```
smb://timemachine-samba.local/timemachine   ← auto-discovered via Avahi
smb://storage-samba.local/storage
```

The timemachine share appears automatically in **System Settings → Time Machine → Add Backup Disk**.

> The hostnames are published dynamically by `samba-avahi-publisher.service` as MetalLB
> assigns IPs to each share's LoadBalancer service — no hardcoded IP is required.

### Resize the Time Machine PVC

Edit the `storage` field in `manifests/samba-share.yaml` **before the PVC is
first created** (PVCs cannot be shrunk after creation):

```yaml
resources:
  requests:
    storage: 4Ti
```

### Resize the storage PVC

Edit `storageShareSize` in `hosts/nas/services.nix`:

```nix
storageShareSize = "20Ti";
```

Note: `local-path-provisioner` does not enforce PVC size limits; this value is
advisory only.

## Grafana

Grafana is exposed via MetalLB on port 80 (the LoadBalancer IP is assigned from
`metallbIpRange`). Find it with:

```bash
kubectl get svc -n monitoring kube-prometheus-stack-grafana
```

The admin password is randomly generated on first deploy and stored in a K8s Secret.
Retrieve it with:

```bash
kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

Login with username `admin` and the password from the command above.

## Auto-upgrades

`system.autoUpgrade` is configured to run weekly (Sunday 03:00, ±30 min jitter).
Each run:

1. Updates the `nixpkgs` flake input (`--update-input nixpkgs`)
2. Rebuilds and switches to the new configuration
3. Reboots if a new kernel was activated (reboot window: 02:00–06:00)

Because k3s is a nixpkgs package, it is automatically kept up to date by this
mechanism. k3s's bundled components (containerd, CoreDNS, Flannel,
local-path-provisioner) are also updated in lock-step.

**Helm chart versions** in `manifests/` are pinned and are **not** auto-bumped.
Review and update them manually when new chart releases are available.

**If the flake is hosted on GitHub**, replace the local path in `services.nix`:

```nix
system.autoUpgrade = {
  flake = "github:youruser/nixos-configs";
  # Remove the --update-input flag; update flake.lock by pushing to the repo.
  flags = [];
  ...
};
```

## Tests

The NixOS VM test (`tests/nas.nix`) validates the following assertion groups:

1. USB boot stick partitioning + GRUB install
2. RAID6 array creation (6 drives)
3. LVM + dm-writecache setup
4. XFS formatting + mount on `/data`
5. SSH hardening (key-only, no root login)
6. User `ben` exists and is in `wheel`
7. Firewall rules (ports 22, 445, 6443, 30030)
8. k3s starts and node reaches Ready
9. Manifest symlinks present (monitoring + MetalLB + Samba)
10. Required packages installed
11. Bash completion available; `kubectl` alias + completion registered
12. kube-system + monitoring pods healthy
13. PVC allocation + write test on `/data/kubernetes`

The test VM needs internet access to pull container images (k3s, monitoring
stack). The nix build sandbox blocks outbound network, so the build passes
`sandbox = false`. This requires your user to be in the nix `trusted-users`
list. Edit the custom nix configuration (Determinate Nix replaces `nix.conf` on updates):

```bash
sudo vim /etc/nix/nix.custom.conf
```

And add (or update) the `trusted-users` line:

```
trusted-users = root ben
```

The test adds a QEMU SLIRP NIC on a dedicated subnet (10.0.10.0/24) for NAT
internet access — see `tests/nas.nix` for details.

## Development setup

### Linux with nix (recommended)

The fastest way to run tests. QEMU uses KVM for hardware-accelerated
virtualisation, so the test VM runs at near-native speed.

1. [Install determinate nix](https://docs.determinate.systems/determinate-nix/#getting-started) if you haven't already.
```
curl -fsSL https://install.determinate.systems/nix | sh -s -- install
```

2. Ensure your user can access `/dev/kvm`:

   ```
   test -w /dev/kvm && echo "I have access" || echo "Permission denied"
   ```

   If you get "Permission denied", add yourself to the `kvm` group:

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

### Interactive mode

To get a Python REPL where you can start the VM and run commands step-by-step:

```bash
./run-tests.sh nas --interactive
```

This builds the `.driver` attribute and launches `nixos-test-driver --interactive`.
From the REPL you can call `nas.start()`, `nas.succeed(...)`, `nas.shell_interact()`, etc.

### Attaching a debug shell to a running test

The test VM exposes a serial console on a Unix socket. While a test is running
(interactive or not), connect from another terminal:

```bash
rlwrap socat - UNIX-CONNECT:/tmp/nas-shell.sock
```

Press Enter once to get a root shell inside the VM. `rlwrap` adds arrow keys
and command history. This is useful for inspecting state while the automated
test is still in progress.

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
- [ ] `hosts/nas/services.nix` — `metallbIpRange` (IP pool for MetalLB, must suit your LAN)
- [ ] `hosts/nas/services.nix` — `sambaTimemachinePassword` (Samba password for `timemachine` user)
- [ ] `hosts/nas/services.nix` — `sambaStoragePassword` (Samba password for `storage` user)
- [ ] `hosts/nas/services.nix` — `storageShareSize` (PVC size for the storage share; default `10Ti`)
- [ ] `hosts/nas/services.nix` — `system.autoUpgrade.flake` (local path or GitHub URL)
- [ ] `manifests/kube-prometheus-stack.yaml` — Alertmanager SMTP credentials and recipient
