#!/usr/bin/env bash
# Deploy this flake to the tablet (over the USB ethernet gadget or Wi-Fi).
#
#   ./deploy.sh [boot|switch|test] [--reboot]   (default: boot)
#
# The tablet is reached via IPv6 link-local on the host's USB interface
# (which nix's ssh:// URLs can't express, so a temporary ssh_config with a
# host alias is passed through NIX_SSHOPTS), or via Wi-Fi as irulu-x18.local
# when no USB link is found.
set -euo pipefail

action=${1:-boot}
cd "$(dirname "$0")"

iface=$(ip -br link | awk '$1 ~ /^enp.*u[0-9]/ && /UP|UNKNOWN/ {print $1; exit}')
host=""
if [ -n "$iface" ]; then
    # Find the tablet: the link-local address on that interface that isn't ours
    own=$(ip -6 -br addr show dev "$iface" | grep -o 'fe80::[0-9a-f:]*' || true)
    addr=$(ping -6 -c2 -w3 "ff02::1%$iface" 2>/dev/null \
           | grep -o 'fe80::[0-9a-f:]*' | grep -vx "${own:-none}" | head -1 || true)
    [ -n "$addr" ] && host="$addr%%$iface"
fi
if [ -z "$host" ]; then
    # No USB link: try Wi-Fi via mDNS
    host=irulu-x18.local
fi
echo "Tablet at ${host/\%\%/%}"

cfg=$(mktemp)
trap 'rm -f "$cfg"' EXIT
cat > "$cfg" <<EOF
Host x18
  HostName $host
  User root
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ${XDG_CACHE_HOME:-$HOME/.cache}/irulu-x18-known_hosts
EOF

NIX_SSHOPTS="-F $cfg" nixos-rebuild "$action" --flake .#irulu-x18 --target-host x18

if [ "${2:-}" = --reboot ]; then
    ssh -F "$cfg" x18 systemctl reboot || true
    echo "Rebooting; the USB link comes back after about a minute."
fi
