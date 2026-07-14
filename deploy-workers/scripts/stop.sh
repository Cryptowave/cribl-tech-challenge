#!/bin/bash
set -euxo pipefail

if systemctl list-unit-files cribl.service >/dev/null 2>&1; then
  systemctl stop cribl || true
elif [ -x /opt/cribl/bin/cribl ]; then
  /opt/cribl/bin/cribl stop || true
fi
