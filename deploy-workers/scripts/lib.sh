# Sourced by the other scripts in this directory - not directly executable.

dnf install -y awscli >/dev/null 2>&1 || true

# Cribl runs as the cribl user (see install.sh) and uses git internally for
# config versioning. Git >=2.35.2 refuses to operate on a repo dir not owned
# by the current UID ("dubious ownership") - leftover root-owned state from
# before this ownership split existed would trip this check. Cribl surfaces
# the resulting git failure as a generic "no versioning available" boot
# error. This hook itself runs as root (see appspec.yml), so the per-user
# git config would land in root's home, not cribl's - use --system instead.
# Trusted, single-purpose instance, so blanket-exempting is fine here.
git config --system --add safe.directory '*' 2>/dev/null || true

_imds_token="$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
CRIBL_DEPLOY_REGION="$(curl -s -H "X-aws-ec2-metadata-token: $_imds_token" http://169.254.169.254/latest/meta-data/placement/region)"
