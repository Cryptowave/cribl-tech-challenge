# `aws-code-deploy-workers/` + `deploy-workers/`

The Worker delivery pipeline. Structurally a mirror of
[the Leader pipeline](aws-code-deploy-leaders.md) — same shape, separate everything.

**State key:** `deploy-worker/terraform.tfstate` · **Targets:** instances tagged `Role=worker`
· **Depends on:** [aws-infrastructure-init](aws-infrastructure-init.md) and a **running
Leader**

## Why it is a separate root at all

Not duplication for its own sake. Leaders and Workers install Cribl in **fundamentally
different ways** — the Leader downloads the release from the CDN and starts standalone; the
Worker is *onboarded by the Leader*, which installs Cribl and registers the node into a worker
group in one call. They also need to roll independently: pushing a change to the Workers should
not touch the Leader HA pair, and vice versa.

Keeping them apart gives each its own CodeDeploy application, deployment group, artifact
bucket, and state key, so a Worker deployment can never take a Leader down as a side effect.

## The Terraform root: `aws-code-deploy-workers/`

Identical in structure to the Leader root, with different values:

| | Leaders | Workers |
| --- | --- | --- |
| CodeDeploy app | `cribl-stream` | `cribl-stream-worker` |
| Artifact bucket | `cribl-deploy-artifacts-minfanger-us-east-2` | `cribl-deploy-artifacts-minfanger-worker-us-east-2` |
| `ec2_tag_filter` | `Role=leader` | `Role=worker` |
| State key | `deploy-leaders/…` | `deploy-worker/…` |
| Deployment config | `OneAtATime` | `OneAtATime` |

Everything else is the same and is explained in detail in
[the Leader doc](aws-code-deploy-leaders.md): a versioned/encrypted/public-access-blocked S3
bucket (`s3.tf`), a CodeDeploy service role plus an inline policy extending the *existing*
instance role with read access to this bucket (`iam.tf`), and an `AWS-ConfigureAWSPackage` SSM
association on a 30-day schedule that keeps the CodeDeploy agent installed on `Role=worker`
hosts (`ssm.tf`).

`OneAtATime` still applies even though there is only one Worker today: there is no HA pairing
between Workers, but they serve live traffic, so a future fleet should still roll host by host
rather than all at once.

---

## The revision bundle: `deploy-workers/`

`appspec.yml`, `stop.sh`, `start.sh`, and `validate.sh` are the same as the Leader's — see
[that doc](aws-code-deploy-leaders.md#the-revision-bundle-deploy-leaders) for the reasoning
behind the start/stop/chown/start sequence in `start.sh` and the fail-and-rollback poll in
`validate.sh`. Two files differ.

### `scripts/lib.sh` — same git fix, plus region discovery

It carries the same `git config --system --add safe.directory '*'` line as the Leader (Cribl's
internal git config versioning trips "dubious ownership" once `/opt/cribl` is owned by the
`cribl` user; `--system` because the hook runs as root, so a per-user setting would land in
root's home and do nothing). On top of that:

```bash
dnf install -y awscli >/dev/null 2>&1 || true

_imds_token="$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
CRIBL_DEPLOY_REGION="$(curl -s -H "X-aws-ec2-metadata-token: $_imds_token" \
  http://169.254.169.254/latest/meta-data/placement/region)"
```

The Worker needs the AWS CLI (the Leader does not) because `install.sh` calls Secrets Manager.
The region is discovered from **IMDSv2** — the `PUT` to get a token first, then the metadata
read with that token — rather than hardcoded, so the same bundle works in any region.

### `scripts/install.sh` — the real difference

```bash
AUTH_TOKEN="$(aws secretsmanager get-secret-value --region "$CRIBL_DEPLOY_REGION" \
  --secret-id cribl-stream/distributed-auth-token --query SecretString --output text)"

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
```

Three things are going on here.

**The Leader onboards the Worker.** Rather than downloading Cribl from the CDN and then
separately registering the node, the script curls the **Leader's own worker-onboarding
endpoint** (`/init/install-worker.sh` on port 9000) and pipes the result to `bash`. That
generated script installs Cribl *and* registers this node into the `default` worker group
against the auth token, in a single step. This is why the Worker deployment must run **after**
the Leader is up — the endpoint it depends on is served by the Leader itself.

**The token is fetched at deploy time, never stored.** It comes from Secrets Manager (created
in [aws-infrastructure-init](aws-infrastructure-init.md#the-distributed-auth-token-secretstf))
via the instance role's scoped `secretsmanager:GetSecretValue` grant. It is not in userdata, an
instance tag, or git.

**The `set +x` / `set -x` pair is a security control, not a style choice.** The script runs
under `set -euxo pipefail`, and `set -x` would print the entire `curl` command line —
**including `token=<the actual secret>` in cleartext** — into the CodeDeploy `AfterInstall`
hook log. Suppressing xtrace around exactly that block keeps it out. `--data-urlencode` handles
query-string escaping for the same values.

`download_url=` is passed empty deliberately: it tells the Leader's onboarding script to serve
the Cribl package itself rather than sending the Worker off to an external URL.

### `deploy.sh`

Identical in shape to the Leader's — reads `artifact_bucket_name`,
`codedeploy_application_name`, and `codedeploy_deployment_group_name` from
`terraform -chdir=../aws-code-deploy-workers output`, zips `appspec.yml` + `scripts/`, uploads
it under a timestamped key (`cribl-worker-deploy-<ts>.zip`), and calls
`aws deploy create-deployment`. No names are hardcoded.

## Usage

```bash
cd aws-code-deploy-workers
terraform init
terraform apply

cd ../deploy-workers
./deploy.sh
```

Run this **after** the Leaders are deployed and healthy.

## Known limitation: the hardcoded Leader IP

```bash
curl -sG 'http://10.0.1.195:9000/init/install-worker.sh' ...
```

That address is `leader-primary`'s private IP, written into the script by hand. **Rebuilding
the Leader gives it a new private IP and this line must be edited** — which is exactly what
happened to me mid-build when I rebuilt the instances to test the pipeline. It is the one real
manual dependency left in the repo.

Two ways out, in increasing order of correctness:

1. **Resolve it at deploy time.** The value is already an output of `aws-infrastructure-init`
   (`instance_private_ips["leader-primary"]`), and the instance role already has
   `ec2:DescribeTags` — so the script could look the Leader up by its `Name` tag instead of
   being told where it is.
2. **Front the Leader pair with an internal NLB.** Workers point at a stable endpoint, and
   `leader-primary` / `leader-passive` become an implementation detail. This is what unlocks
   *true* failover with no human in the loop: today the Workers are onboarded against the
   primary's address specifically, so a failover to `leader-passive` still needs intervention.
