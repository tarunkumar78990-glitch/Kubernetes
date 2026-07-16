#!/bin/bash
set -euxo pipefail

# The bastion is deliberately minimal. It is a door, not a workshop.
apt-get update
apt-get install -y tinyproxy kubectl google-cloud-cli-gke-gcloud-auth-plugin || true
apt-get install -y curl wget net-tools

echo "bastion ready" > /var/log/startup-complete.log
