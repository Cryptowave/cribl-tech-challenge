#!/bin/bash
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

sudo systemctl start cribl
sudo systemctl stop cribl
sudo chown -R cribl:cribl /opt/cribl
sudo systemctl start cribl
