# Sourced by the other scripts in this directory - not directly executable.

# Cribl runs as the cribl user (see install.sh) and uses git internally for
# config versioning. Git >=2.35.2 refuses to operate on a repo dir not owned
# by the current UID ("dubious ownership") - leftover root-owned state from
# before this ownership split existed would trip this check. Cribl surfaces
# the resulting git failure as a generic "no versioning available" boot
# error. This hook itself runs as root (see appspec.yml), so the per-user
# git config would land in root's home, not cribl's - use --system instead.
# Trusted, single-purpose instance, so blanket-exempting is fine here.
git config --system --add safe.directory '*' 2>/dev/null || true
