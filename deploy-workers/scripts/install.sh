#!/bin/bash
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

id -u cribl &>/dev/null || useradd -r -s /sbin/nologin -d /opt/cribl -M cribl

# The distributed auth token is sensitive and shared with the leader (see
# terraform-app/secrets.tf) - pull it from Secrets Manager at deploy time
# rather than baking it into this script or the master's onboarding URL.
AUTH_TOKEN="$(aws secretsmanager get-secret-value --region "$CRIBL_DEPLOY_REGION" \
  --secret-id cribl-stream/distributed-auth-token --query SecretString --output text)"

mkdir -p /opt/cribl

# Master's own worker-onboarding endpoint installs Cribl and registers it
# under this token/group. --data-urlencode handles query-string escaping;
# the set +x/-x pair keeps the token out of the AfterInstall hook's xtrace
# log, since `set -x` would otherwise print it in cleartext. Please not that
# this is where the value for the primary or secondary leader is set. I'd 
# like to change this such that we can have true failover without human
# intervention. 
{
  set +x
  curl -sG 'http://10.0.1.195:9000/init/install-worker.sh' \
    --data-urlencode 'group=default' \
    --data-urlencode "token=$AUTH_TOKEN" \
    --data-urlencode 'download_url=' \
    --data-urlencode 'user=cribl' \
    --data-urlencode 'user_group=cribl' \
    --data-urlencode 'install_dir=/opt/cribl' | bash -
  set -x
}

sudo chown -R cribl:cribl /opt/cribl
systemctl daemon-reload
