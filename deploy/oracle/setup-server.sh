#!/bin/bash
#
# One-off preparation of a fresh Oracle Cloud Ubuntu VM for DM-CRM:
# Docker, firewall rules for HTTP/HTTPS and a swap file.
# Run as the default "ubuntu" user: bash setup-server.sh

set -euo pipefail

echo "== packages"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg iptables-persistent

echo "== docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
fi
sudo usermod -aG docker "$USER"

echo "== firewall"
# Oracle's Ubuntu images reject everything except SSH in iptables, on top of
# the cloud security list. Allow web traffic before the final REJECT rule.
for port in 80 443; do
  # drop a rule left after the REJECT by an earlier run, then insert before it
  while sudo iptables -C INPUT -p tcp --dport "$port" -m state --state NEW -j ACCEPT 2>/dev/null; do
    sudo iptables -D INPUT -p tcp --dport "$port" -m state --state NEW -j ACCEPT
  done
  reject=$(sudo iptables -L INPUT --line-numbers -n | awk '$2 == "REJECT" { print $1; exit }')
  sudo iptables -I INPUT "${reject:-1}" -p tcp --dport "$port" -m state --state NEW -j ACCEPT
done
sudo netfilter-persistent save

echo "== swap"
if ! swapon --show | grep -q /swapfile; then
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

echo "== done (log out and back in for docker group membership)"
