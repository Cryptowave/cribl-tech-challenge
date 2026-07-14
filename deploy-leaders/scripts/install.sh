#!/bin/bash
set -euxo pipefail

id -u cribl &>/dev/null || useradd -r -s /sbin/nologin -d /opt/cribl -M cribl

mkdir -p /opt
cd /opt
sudo curl -Lso - "$(curl -s https://cdn.cribl.io/dl/latest-x64)" | sudo tar zxv

sudo chown -R cribl:cribl /opt/cribl

# Register Cribl as a systemd service. Running it directly from the hook
# script leaves the daemon in the same process group as the hook, so
# CodeDeploy kills it when the ApplicationStart hook exits - systemd
# detaches it properly. Safe to re-run on every deploy. Use Cribl's own
# boot-start command rather than hand-authoring a unit file, so the unit
# stays in sync with whatever this Cribl version expects.
sudo /opt/cribl/bin/cribl boot-start enable -u cribl
systemctl daemon-reload
