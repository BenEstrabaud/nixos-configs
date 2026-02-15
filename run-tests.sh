#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_NAME="${1:-nas}"
NIX_IMAGE="nixos/nix:2.24.12"

# ---------- Helpers ----------

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

die() { red "ERROR: $*" >&2; exit 1; }

# ---------- Detect environment ----------

# Resolve nix binary — may not be on $PATH.
NIX_BIN=""
if command -v nix &>/dev/null; then
    NIX_BIN="nix"
elif [[ -x /nix/var/nix/profiles/default/bin/nix ]]; then
    NIX_BIN="/nix/var/nix/profiles/default/bin/nix"
fi

# 1. Native nix on Linux — fastest path (KVM acceleration if available).
if [[ -n "$NIX_BIN" ]] && [[ "$(uname -s)" == "Linux" ]]; then
    bold "Running NixOS VM test natively with nix..."
    bold "Test: ${TEST_NAME}"
    exec "$NIX_BIN" build "${REPO_DIR}#checks.x86_64-linux.${TEST_NAME}" \
        --extra-experimental-features 'nix-command flakes' \
        --print-build-logs --no-link
fi

# 2. Fall back to Docker (macOS, or Linux without nix).
command -v docker &>/dev/null || die "Docker not found. Install nix (on Linux) or Docker."
docker info &>/dev/null 2>&1  || die "Docker daemon is not running."

bold "Running NixOS VM test in Docker (nixos/nix)..."
bold "Test: ${TEST_NAME}"

# Use --privileged so /dev/kvm is accessible if the host exposes it.
# Claim kvm in system-features so nix allows the build; the QEMU start
# script checks for /dev/kvm at runtime and falls back to TCG emulation
# when it is absent (common on Docker Desktop for Mac).
DOCKER_TTY=""
[ -t 0 ] && DOCKER_TTY="-t"

HAS_KVM=""
docker run --rm --privileged "${NIX_IMAGE}" \
    sh -c 'test -c /dev/kvm' 2>/dev/null && HAS_KVM=1 || true

if [ -n "$HAS_KVM" ]; then
    bold "KVM detected — hardware acceleration enabled"
else
    bold "No KVM — QEMU will use software emulation (slow)"
fi
echo

docker run --rm -i ${DOCKER_TTY} \
    --privileged \
    -v "${REPO_DIR}:/workspace" \
    -w /workspace \
    "${NIX_IMAGE}" \
    sh -c '
        mkdir -p /etc/nix
        cat >> /etc/nix/nix.conf <<EOF
experimental-features = nix-command flakes
sandbox = false
system-features = kvm nixos-test benchmark big-parallel
EOF

        echo ">>> Building .#checks.x86_64-linux.'"${TEST_NAME}"'"
        nix build ".#checks.x86_64-linux.'"${TEST_NAME}"'" --print-build-logs --no-link
    '

green "Test '${TEST_NAME}' passed."
