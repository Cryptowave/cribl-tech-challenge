# `aws-code-deploy-leaders/` + `deploy-leaders/`

The Leader delivery pipeline, in two halves:

- **`aws-code-deploy-leaders/`** — the Terraform root that builds the CodeDeploy plumbing
  (artifact bucket, application, deployment group, IAM, agent install).
- **`deploy-leaders/`** — the CodeDeploy *revision bundle*: `appspec.yml`, the lifecycle hook
  scripts, and `deploy.sh` to package and trigger a deployment.

**State key:** `deploy-leaders/terraform.tfstate` · **Targets:** instances tagged `Role=leader`
· **Depends on:** [aws-infrastructure-init](aws-infrastructure-init.md)

## The Terraform root: `aws-code-deploy-leaders/`

### `s3.tf` — the artifact bucket

`cribl-deploy-artifacts-minfanger-us-east-2`, with versioning enabled, SSE-S3 (AES256)
encryption by default, and all four public-access-block flags set. Versioning is the useful
one: CodeDeploy revisions are addressed by key, and versioning means a redeployed key can
still be traced back.

### `codedeploy.tf` — the application and deployment group

```hcl
resource "aws_codedeploy_deployment_group" "cribl" {
  service_role_arn       = aws_iam_role.codedeploy_service.arn
  deployment_config_name = "CodeDeployDefault.OneAtATime"

  ec2_tag_filter {
    key   = "Role"      # var.deployment_group_tag
    type  = "KEY_AND_VALUE"
    value = "leader"
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}
```

The deployment group is defined **entirely by the `Role=leader` tag** — no instance IDs, no
Auto Scaling group. Replace an instance and it joins the group automatically.

`OneAtATime` is a deliberate choice, not a default: `leader-primary` and `leader-passive` are
an HA pair, so bringing them both down simultaneously would defeat the point of having two.
Auto-rollback on `DEPLOYMENT_FAILURE` pairs with `validate.sh` below — if the new revision
does not come up healthy, CodeDeploy reverts to the last known-good one on its own.

### `iam.tf` — two roles, only one of them new

1. **The CodeDeploy service role** (`cribl-stream-codedeploy-service-role`), assumed by
   `codedeploy.amazonaws.com` with the AWS-managed `AWSCodeDeployRole` attached. This is what
   lets the CodeDeploy *service* call EC2/ASG/ELB APIs to find and orchestrate the instances.

2. **An extension of the existing instance role.** The agent that runs *on each host* needs to
   pull the revision bundle out of S3, and that host already has a role from
   `aws-infrastructure-init`. So this root looks it up rather than creating another:

   ```hcl
   data "aws_iam_role" "instance" { name = var.instance_role_name }  # cribl-stream-app-ssm-role

   resource "aws_iam_role_policy" "instance_artifact_bucket_read" {
     role   = data.aws_iam_role.instance.name
     policy = # s3:GetObject, s3:GetObjectVersion on <bucket>/*, s3:ListBucket on <bucket>
   }
   ```

   Scoped to this one bucket. `GetObjectVersion` is there because the bucket is versioned.

### `ssm.tf` — getting the CodeDeploy agent onto the hosts

The CodeDeploy agent is not on the AL2023 AMI, and it is not installed in userdata. Instead:

```hcl
resource "aws_ssm_association" "codedeploy_agent" {
  name = "AWS-ConfigureAWSPackage"
  parameters = { action = "Install", name = "AWSCodeDeployAgent" }
  targets { key = "tag:Role", values = ["leader"] }
  schedule_expression = "rate(30 days)"
}
```

This works because every instance already carries `AmazonSSMManagedInstanceCore`. Doing it via
an SSM *association* rather than userdata means it is **continuously enforced**: the schedule
re-runs every 30 days, so the agent gets reinstalled if it is removed and updated as AWS
publishes new versions. An instance that boots into the `Role=leader` tag picks the agent up
without anyone touching it.

---

## The revision bundle: `deploy-leaders/`

### `appspec.yml`

```yaml
files:
  - source: /
    destination: /opt/cribl-deploy

hooks:
  ApplicationStop:  scripts/stop.sh      (60s,  root)
  AfterInstall:     scripts/install.sh   (300s, root)
  ApplicationStart: scripts/start.sh     (60s,  root)
  ValidateService:  scripts/validate.sh  (60s,  root)
```

The bundle contents land in `/opt/cribl-deploy`; Cribl itself installs to `/opt/cribl`. All
hooks run as root. `AfterInstall` gets 300s because it downloads and untars the full Cribl
release.

### `scripts/stop.sh` — `ApplicationStop`

Stops the service if it exists, tolerating both worlds: `systemctl stop cribl` if the unit
file is registered, else `/opt/cribl/bin/cribl stop` if the binary is there, else nothing.
Both paths are `|| true`. This hook runs *from the previously deployed revision*, so on a
first-ever deployment it does not run at all — it has to be safe when nothing is installed.

### `scripts/install.sh` — `AfterInstall`

```bash
id -u cribl &>/dev/null || useradd -r -s /sbin/nologin -d /opt/cribl -M cribl

cd /opt
sudo curl -Lso - "$(curl -s https://cdn.cribl.io/dl/latest-x64)" | sudo tar zxv
sudo chown -R cribl:cribl /opt/cribl

sudo /opt/cribl/bin/cribl boot-start enable -u cribl
systemctl daemon-reload
```

The nested `curl` is Cribl's own "latest release" indirection — the inner call returns the
current download URL, the outer one streams it straight into `tar`. Nothing pins a version;
each deployment picks up the current release.

**The `boot-start enable` line is the interesting one, and it exists because of a real
failure.** Running the daemon directly from the hook script leaves it in the same process
group as the hook, so **CodeDeploy kills it the moment the `ApplicationStart` hook exits** —
the deployment goes green and the service is dead. Registering it as a systemd unit detaches
it properly. Using Cribl's own `boot-start` command rather than hand-writing a unit file
keeps the unit in sync with whatever the installed Cribl version expects. It is idempotent, so
re-running it on every deployment is fine.

### `scripts/lib.sh` — sourced, not executed

One thing, with a long comment explaining it:

```bash
git config --system --add safe.directory '*' 2>/dev/null || true
```

Cribl runs as the `cribl` user and uses git internally for config versioning. Git ≥ 2.35.2
refuses to operate on a repo directory not owned by the current UID ("dubious ownership"), and
any leftover root-owned state trips that check. Cribl surfaces the resulting git failure as a
generic "no versioning available" boot error, which is not remotely obvious to debug.

`--system` rather than the usual per-user config specifically because **the hook runs as
root** — a per-user setting would land in root's home directory, not `cribl`'s, and have no
effect on the process that actually needs it. Blanket-exempting all directories is acceptable
on a single-purpose, trusted instance.

### `scripts/start.sh` — `ApplicationStart`

```bash
sudo systemctl start cribl
sudo systemctl stop cribl
sudo chown -R cribl:cribl /opt/cribl
sudo systemctl start cribl
```

The start/stop/chown/start dance is not an accident. Cribl's first startup **creates files
under `/opt/cribl` as it initializes** (config, local state), and depending on how it was
launched some of those land root-owned. Starting once lets that initialization happen,
stopping quits cleanly, the `chown` fixes ownership of everything that just got created, and
the final start brings it up running properly as `cribl` with a directory it fully owns.

### `scripts/validate.sh` — `ValidateService`

Polls `systemctl is-active --quiet cribl` ten times with a 3-second sleep (≈30s of grace),
exiting 0 the moment it reports active. If it never does, it dumps `systemctl status` and
**exits non-zero — which is what trips the deployment group's auto-rollback.** This is the
gate that makes `auto_rollback_configuration` meaningful; without a validate hook that can
fail, every deployment succeeds by definition.

### `deploy.sh` — packaging and triggering

```bash
TF_DIR="$SCRIPT_DIR/../aws-code-deploy-leaders"

BUCKET="$(terraform -chdir="$TF_DIR" output -raw artifact_bucket_name)"
APPLICATION="$(terraform -chdir="$TF_DIR" output -raw codedeploy_application_name)"
DEPLOYMENT_GROUP="$(terraform -chdir="$TF_DIR" output -raw codedeploy_deployment_group_name)"

zip -r "$BUNDLE_PATH" appspec.yml scripts/
aws s3 cp "$BUNDLE_PATH" "s3://$BUCKET/cribl-deploy-$TIMESTAMP.zip"
aws deploy create-deployment --application-name "$APPLICATION" ...
```

Every name is read back from **Terraform outputs**, not hardcoded — rename the bucket or the
application in Terraform and this script keeps working. The bundle key is timestamped
(`cribl-deploy-20260714T0530.zip`), so combined with bucket versioning every deployment is
individually addressable and re-deployable.

It prints the deployment ID and the command to follow it:

```
Started deployment: d-XXXXXXXXX
Track with: aws deploy get-deployment --deployment-id d-XXXXXXXXX --region us-east-2
```

## Usage

```bash
cd aws-code-deploy-leaders
terraform init
terraform apply

cd ../deploy-leaders
./deploy.sh
```

Requires the AWS CLI and `zip` locally, plus AWS credentials under the `default` profile.

## Notes

- **The bucket name is globally unique and therefore hardcoded as a default**
  (`cribl-deploy-artifacts-minfanger-us-east-2`). Deploying this in another account means
  overriding `artifact_bucket_name` — bucket naming collisions caught me twice during this
  build.
- **Nothing pins the Cribl version.** `install.sh` always pulls `latest-x64`. Deliberate for a
  challenge; in production the release URL belongs in a variable so a rollback is a version
  change rather than a hope that the CDN still serves the old build.
