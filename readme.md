# Cribl Stream on AWS — Tech Challenge

A distributed Cribl Stream deployment (two Leaders in an HA pair, one Worker) built with
Terraform and rolled out with CodeDeploy, monitored by CloudWatch, and alerting by email
through SNS → Lambda → SES.

Everything is deployed into **us-east-2**.

For the full end-to-end design — network layout, HA model, deploy flow, and alerting path —
see [`docs/architecture.md`](docs/architecture.md).

---

## **Start Time Tech Challenge**

**Start Time: 4:47am Mountain Time** (Don't worry — I was on an overnight change window.)

## **End Time Tech Challenge**

**Complete Time Tech Work: 6:20am — 1 Hour 33 Minutes**

Sorry about that, got down a rabbit hole with DNS for the email alerts.

As a subnote to the above: documentation took a bit long too, mostly trying to format it
all correctly.

---

## Pre-requisites

1. **DNS for email.** SES needs a verifiable sending domain. I already had
   `merleinfanger.com` configured in my AWS account, so the alert sender
   (`alerts@merleinfanger.com`) lives there. If you use a different domain, change
   `sender_domain` / `alert_from_address` in `aws-notification-configuration/variables.tf`.
2. **An S3 bucket for Terraform state.** I created this **outside of Terraform** — I prefer
   that to starting local and migrating state later. Every root here points its backend at
   `stream-state-minfanger-us-east-2` with a distinct state key, and uses `use_lockfile`
   (S3 native locking, no DynamoDB table needed).
3. **Terraform installed locally, version 1.5 minimum.** Every root pins
   `required_version >= 1.5.0`. The AWS CLI and `zip` are also needed for the CodeDeploy
   `deploy.sh` scripts, plus AWS credentials under the `default` profile.

---

## What's in here

Each directory below is its own Terraform root (its own state key) or its own CodeDeploy
revision bundle. The summaries here are the short version — each links to a full code
walkthrough in [`docs/`](docs/README.md).

### [`aws-networking-setup/`](docs/aws-networking-setup.md)

The foundation layer: a `10.0.0.0/16` VPC with DNS support enabled, an internet gateway,
three public `/24` subnets spread one-per-AZ, and a public route table sending `0.0.0.0/0`
at the IGW. It exports `vpc_id`, `vpc_cidr_block`, and `public_subnet_ids`, which the later
layers read via `terraform_remote_state` — that remote-state read is the only coupling
between roots.

### [`aws-infrastructure-init/`](docs/aws-infrastructure-init.md)

The compute and security layer. Three `t3.medium` Amazon Linux 2023 instances on 100 GB gp3
root volumes — `leader-primary`, `leader-passive`, `worker` — created from a `for_each` map
of name → role, each tagged `Role=leader|worker`. That tag is what CodeDeploy and the SSM
associations later target. Security groups are least-privilege and reference *each other*
rather than CIDRs: the Leader SG allows the UI on 9000 only from `admin_cidr_blocks`, the
control channel on 4200 from the Worker SG, and 4200 leader-to-leader via `self`. A
32-character auth token for the distributed control channel is generated with
`random_password` and stored in Secrets Manager, so it is never typed or committed;
instances read it at deploy time through their instance role. The userdata installs `git`
and the CloudWatch agent, and writes the agent config that publishes CPU/memory/disk plus
the `procstat` `pid_count` metric the alarms later key on.

**Requires a `terraform.tfvars`** — `admin_cidr_blocks` has no default on purpose (see
deployment step 2).

### [`aws-code-deploy-leaders/`](docs/aws-code-deploy-leaders.md) + [`deploy-leaders/`](docs/aws-code-deploy-leaders.md#the-revision-bundle-deploy-leaders)

The Leader delivery pipeline. `aws-code-deploy-leaders/` builds the plumbing: a versioned,
encrypted, public-access-blocked S3 artifact bucket; a CodeDeploy application and deployment
group scoped by `ec2_tag_filter` to `Role=leader`; the CodeDeploy service role; an inline
policy granting the *existing* instance role read access to the artifact bucket; and an SSM
association (`AWS-ConfigureAWSPackage`) that installs and keeps the CodeDeploy agent current
on tagged hosts. The deployment config is `OneAtATime` with auto-rollback on failure, so the
HA pair never goes down together.

`deploy-leaders/` is the revision bundle itself — `appspec.yml` plus lifecycle hooks that
stop the service, download and untar the latest Cribl release, register it as a systemd unit
via `cribl boot-start`, start it, and validate that it came up. `./deploy.sh` zips the
bundle, uploads it, and triggers the deployment, reading the bucket/app/group names from
Terraform outputs so nothing is hardcoded.

### [`aws-code-deploy-workers/`](docs/aws-code-deploy-workers.md) + [`deploy-workers/`](docs/aws-code-deploy-workers.md#the-revision-bundle-deploy-workers)

The Worker delivery pipeline. Structurally a mirror of the Leader one — separate CodeDeploy
application, deployment group, and artifact bucket, scoped to `Role=worker`. The meaningful
difference is in `install.sh`: instead of downloading Cribl from the CDN, the Worker pulls
the auth token out of Secrets Manager and curls the **Leader's own worker-onboarding
endpoint** (`/init/install-worker.sh`), which installs Cribl *and* registers the node into
the `default` worker group in one shot. A `set +x` / `set -x` pair around that block keeps
the token out of the xtrace log.

> **Known wart:** the Leader IP in `deploy-workers/scripts/install.sh` is hardcoded
> (`10.0.1.195`). Rebuilding the Leader means editing it — see
> [Known limitations](docs/README.md#known-limitations).

### [`aws-notification-configuration/`](docs/aws-notification-configuration.md)

Monitoring and alerting. One CloudWatch alarm per instance (built with `for_each` over the
`instance_ids` output from `aws-infrastructure-init`) on the `procstat_lookup_pid_count`
metric: `Minimum < 1` for two consecutive 60s periods means the Cribl process is gone, and
`treat_missing_data = "breaching"` means a wedged or powered-off host alarms too instead of
sitting in `INSUFFICIENT_DATA` forever. Alarms publish to an SNS topic, which invokes a
Python 3.12 Lambda that recovers the instance name from the alarm name and sends an SES
email. SES is verified at the domain level with Easy DKIM, so the sender needs no inbox —
but that means the DNS records have to be published before mail flows. This is the rabbit
hole referenced above.

---

## Deployment steps

### 1. Networking

```bash
cd aws-networking-setup
terraform init
terraform apply
```

Ensure the region you are targeting is correctly specified — in my code I use **us-east-2**
(set in each root's `provider.tf` and `backend.tf`).

### 2. Supporting infrastructure

```bash
cd aws-infrastructure-init
terraform init
terraform apply
```

You will need to **create a `terraform.tfvars`** to define the IPs allowed to reach the
Leader UI. Example structure:

```hcl
admin_cidr_blocks = ["yourIPRange"]
```

> **NOTE:** The userdata here installs the required `git` binary on the instance along with
> the pre-reqs for CloudWatch monitoring.

### 3. Leaders

```bash
cd aws-code-deploy-leaders
terraform init
terraform apply

cd ../deploy-leaders
./deploy.sh
```

Run Terraform in `aws-code-deploy-leaders` to stand up the pipeline, then migrate to
`deploy-leaders` and invoke `./deploy.sh` to trigger it.

> **Manual step — required before Workers will join.** Once the deploy finishes, log in to
> the UI on **both** Leader nodes (`https://<leader-ip>:9000`) and complete the initial
> configuration on each:
>
> 1. Set the admin credentials (first login prompts for them).
> 2. Set the node's mode to **Leader** (distributed mode).
> 3. Change the **registration token** to match the value Terraform generated and wrote to
>    `cribl-stream/distributed-auth-token` in Secrets Manager:
>
>    ```bash
>    aws secretsmanager get-secret-value \
>      --secret-id cribl-stream/distributed-auth-token \
>      --region us-east-2 --query SecretString --output text
>    ```
>
> This has to be done on **both** Leaders — the Worker's `install.sh` pulls that same token
> out of Secrets Manager, so the tokens must match or registration fails.

### 4. Workers

```bash
cd aws-code-deploy-workers
terraform init
terraform apply

cd ../deploy-workers
./deploy.sh
```

Same pattern — `aws-code-deploy-workers` for the pipeline, `deploy-workers` to trigger the
deployment.

### 5. Notifications

```bash
cd aws-notification-configuration
terraform init
terraform apply
terraform output sender_dns_records
```

Then create the necessary DNS records for email (one `_amazonses` TXT record proving domain
ownership, and three DKIM CNAMEs). **Not necessary if CloudWatch monitoring on its own is
sufficient** — the alarms and the SNS topic work regardless; it is only the email leg that
depends on DNS.

If your SES account is still in the sandbox, the recipient address must also be a verified
identity. `verify_recipient_identity = true` (the default) creates it, and you click the link
AWS emails you. Set it to `false` once the account has production access.

---

## Considerations

Things I'd have taken further with more time on the clock.

### Recovery and resilience

The biggest one. I'm not happy that failover between the Leaders — getting the Worker to
re-join the surviving Leader — is a manual process. I'm genuinely unsure whether that would
bite in a real-world deployment, but without a license to configure Cribl's built-in
resilience settings, this was the best I could come up with inside the time constraints. If
I went deeper here it would be on automating that recovery path end to end rather than
documenting it as a runbook step.

### Deployment automation

The deploy is pipeline-based but manually triggered. The obvious next steps are to have it
deploy automatically on detection of a new binary being available, or to trigger a pipeline
that asks for authorization when a new release lands. I kept it to a simple manual-trigger
deploy pipeline to stay inside the time budget — hopefully close enough to convey the spirit
and direction of thought for continuous deployment to the application. There's probably a lot
more to do here in the real world, but it works.

### Documentation

I used Claude for a lot of the READMEs and didn't have as much time as I'd like to break them
down and review them line by line. With more time, more human review would have happened. That
said, I think what's here is fully usable in its current state.

---

## Recovery steps workbook

When an email notification arrives indicating an instance is down:

1. **Log in to the instance with SSM** and validate that the Cribl service is healthy.

   ```bash
   aws ssm start-session --target <instance-id> --region us-east-2
   sudo systemctl status cribl
   ```

2. **If the instance cannot be reached or the service cannot be recovered**, fail over to the
   other Leader. Edit `deploy-workers/scripts/install.sh` and change the Leader IP to the
   secondary Leader's IP.

3. **Re-run the Worker deployment** to cut the Worker over to the healthy Leader:

   ```bash
   cd deploy-workers
   ./deploy.sh
   ```

   The Worker re-registers against the Leader IP in `install.sh`, so this is what actually
   moves it to the surviving node.

---

## AI usage

This was built primarily with **Claude Sonnet** on a standard Claude Pro subscription. The
whole process — infrastructure, deployment scripts, and documentation — consumed roughly
**43% of the credit balance for a daily window**.
