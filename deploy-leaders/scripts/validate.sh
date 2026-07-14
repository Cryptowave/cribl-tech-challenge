#!/bin/bash
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Give the process a few seconds to come up before declaring failure -
# a non-zero exit here trips the deployment group's auto-rollback.
for i in $(seq 1 10); do
  if systemctl is-active --quiet cribl; then
    exit 0
  fi
  sleep 3
done

echo "cribl.service did not report active after install" >&2
systemctl status cribl --no-pager || true
exit 1
