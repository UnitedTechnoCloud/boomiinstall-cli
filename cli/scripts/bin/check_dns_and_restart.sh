#!/bin/bash

# CONFIGURATION
AWS_REGION="us-east-1"
HOSTNAME=$(hostname)

echo "$(date): Applying default DNS settings..."

# Apply default DNS config
sudo bash -c 'cat <<EOF > /etc/systemd/resolved.conf
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=9.9.9.9
DNSStubListener=yes
Domains=~. ~ec2.internal
EOF'

# Fix symbolic link to prevent degraded DNS warning
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Restart systemd-resolved service
sudo systemctl restart systemd-resolved

echo "$(date): DNS configuration completed."
