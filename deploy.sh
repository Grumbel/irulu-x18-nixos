#!/usr/bin/env bash
# Deploy this flake to the tablet over the USB ethernet gadget.
#
#   ./deploy.sh [boot|switch|test] [--reboot]   (default: boot)
#
# The tablet is reached via IPv6 link-local on the host's USB interface,
# which nix's ssh:// URLs can't express, so a temporary ssh_config with a
# host alias is passed through NIX_SSHOPTS.
set -euo pipefail

action=${1:-boot}
cd "$(dirname "$0")"

iface=$(ip -br link | awk '$1 ~ /^enp.*u[0-9]/ && /UP|UNKNOWN/ {print $1; exit}')
if [ -z "$iface" ]; then
    echo "No USB gadget interface found; is the tablet connected and booted?" >&2
    exit 1
fi

# Find the tablet: the link-local address on that interface that isn't ours
own=$(ip -6 -br addr show dev "$iface" | grep -o 'fe80::[0-9a-f:]*' || true)
addr=$(ping -6 -c2 -w3 "ff02::1%$iface" 2>/dev/null \
       | grep -o 'fe80::[0-9a-f:]*' | grep -vx "${own:-none}" | head -1 || true)
if [ -z "$addr" ]; then
    echo "Tablet not answering on $iface" >&2
    exit 1
fi
echo "Tablet at $addr%$iface"

cfg=$(mktemp)
trap 'rm -f "$cfg"' EXIT
cat > "$cfg" <<EOF
Host x18
  HostName $addr%%$iface
  User root
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ${XDG_CACHE_HOME:-$HOME/.cache}/irulu-x18-known_hosts
EOF

NIX_SSHOPTS="-F $cfg" nixos-rebuild "$action" --flake path:.#irulu-x18 --target-host x18

if [ "${2:-}" = --reboot ]; then
    ssh -F "$cfg" x18 systemctl reboot || true
    echo "Rebooting; the USB link comes back after about a minute."
fi
