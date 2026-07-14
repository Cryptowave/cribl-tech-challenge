# `aws-infrastructure-init/`

The compute and security layer: the three EC2 instances, the security groups between them,
the IAM instance role, the shared distributed-mode auth token, and the userdata that
bootstraps CloudWatch monitoring.

**State key:** `app/terraform.tfstate` · **Region:** `us-east-2` · **Depends on:**
[aws-networking-setup](aws-networking-setup.md)

> **This root requires a `terraform.tfvars`.** `admin_cidr_blocks` has no default, on purpose
> — a typo'd or forgotten value should fail the plan, not silently open the Leader UI to the
> internet.
>
> ```hcl
> admin_cidr_blocks = ["yourIPRange"]
> ```

## Files

| File | Purpose |
| --- | --- |
| `data.tf` | Remote state from the networking layer; latest AL2023 AMI lookup |
| `main.tf` | The three EC2 instances |
| `security_groups.tf` | Leader SG and Worker SG |
| `iam.tf` | Instance role, SSM + CloudWatch managed policies, the extra inline policy |
| `secrets.tf` | The generated distributed-mode auth token in Secrets Manager |
| `userdata.sh` | Installs `git` + the CloudWatch agent, writes the agent config |
| `variables.tf` | Instance type, the instance name → role map, `admin_cidr_blocks` |
| `outputs.tf` | `instance_ids`, `instance_private_ips`, `auth_token_secret_arn` |

## Walkthrough

### Where the instances come from (`data.tf`)

Two data sources. The first reads the networking layer's state directly out of S3:

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = { bucket = "stream-state-minfanger-us-east-2", key = "network/terraform.tfstate", region = "us-east-2" }
}
```

The second resolves the newest Amazon Linux 2023 x86_64 EBS HVM AMI at plan time
(`most_recent = true`, `owners = ["amazon"]`), so the AMI ID is never pinned in code and
never goes stale.

### The instances (`main.tf`)

The whole fleet is one `for_each` over a name → role map:

```hcl
variable "instances" {
  default = {
    "leader-primary" = "leader"
    "leader-passive" = "leader"
    "worker"         = "worker"
  }
}

resource "aws_instance" "app" {
  for_each = var.instances

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type       # t3.medium
  subnet_id              = data.terraform_remote_state.network.outputs.public_subnet_ids[0]
  vpc_security_group_ids = [
    each.value == "leader" ? aws_security_group.leader.id : aws_security_group.worker.id
  ]
  iam_instance_profile = aws_iam_instance_profile.ssm.name
  user_data            = file("${path.module}/userdata.sh")

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  tags = {
    Name        = each.key
    Application = "cribl-stream"
    Role        = each.value     # ← the contract with everything downstream
  }
}
```

Three things to notice:

1. **The `Role` tag is the integration point for the entire rest of the repo.** Both
   CodeDeploy deployment groups select their instances with an `ec2_tag_filter` on
   `Role=leader` / `Role=worker`, both SSM associations install the CodeDeploy agent by
   targeting it, and the Worker's `configure` step reads its own `Role` tag off the instance.
   Nothing downstream refers to an instance ID.
2. **The SG is chosen by role inline**, with a ternary on `each.value`. Adding a second Worker
   is a one-line change to the `instances` map.
3. **100 GB gp3 root volume.** Cribl persists queues and config to disk; the AL2023 default
   root volume is far too small for that.

**Known gap:** all three instances go into `public_subnet_ids[0]` — the same subnet, and
therefore the same AZ. The three-AZ subnets exist in the networking layer; the HA pair should
be spread across them (`public_subnet_ids[index]`). It is the single highest-value change to
make to this file.

### Security groups (`security_groups.tf`)

The rules are written as *relationships between groups*, not as CIDR ranges — the only place
a raw CIDR appears on ingress is the human admin path.

**Leader SG:**

| Port | Source | Why |
| --- | --- | --- |
| 9000 | `var.admin_cidr_blocks` | Leader UI, for humans. The only CIDR-based ingress rule anywhere. |
| 4200 | Worker SG | Worker → Leader control channel: heartbeat, metrics, leader requests, config bundle downloads. |
| 9000 | Worker SG | Worker → Leader UI/API. |
| 4200 | `self` | Leader ↔ Leader distributed API. Both leaders run Cribl continuously under `resiliency: failover`, so they talk to each other. |
| all | egress `0.0.0.0/0` | Required for SSM, CloudWatch, S3, the Cribl CDN. |

**Worker SG:** egress only. It has *no ingress rules at all* — nothing needs to initiate a
connection to a Worker. All Worker traffic is outbound: to the Leader, to SSM, to Secrets
Manager, to CloudWatch.

Referencing the Worker SG by ID rather than by CIDR means adding Workers requires no rule
changes, and it means an instance in the VPC that is not in the Worker SG cannot reach the
Leader's control channel even from the same subnet.

### IAM (`iam.tf`)

One role, `cribl-stream-app-ssm-role`, assumed by `ec2.amazonaws.com`, with:

- **`AmazonSSMManagedInstanceCore`** (AWS managed) — makes the box an SSM managed instance:
  Session Manager access with no SSH keys and no port 22 anywhere in the security groups, and
  the ability to receive the `AWS-ConfigureAWSPackage` association that installs the
  CodeDeploy agent.
- **`CloudWatchAgentServerPolicy`** (AWS managed) — lets the agent publish metrics.
- **An inline policy** with exactly two statements:
  - `ec2:DescribeTags` — so a script on the box can read its own `Role` tag and behave
    accordingly.
  - `secretsmanager:GetSecretValue` scoped to **the single auth-token secret ARN**, not `*`.

The role is later *extended* by each CodeDeploy root, which attaches an inline policy granting
read access to its own artifact bucket. That is why `aws-code-deploy-*/iam.tf` looks the role
up with `data "aws_iam_role"` instead of creating one.

### The distributed auth token (`secrets.tf`)

```hcl
resource "random_password" "auth_token" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "auth_token" {
  name = "cribl-stream/distributed-auth-token"
}

resource "aws_secretsmanager_secret_version" "auth_token" { ... }
```

Cribl's Leader and Workers authenticate the distributed control channel (port 4200) with a
shared token. Generating it here means it is **never typed by a human and never committed**:
Terraform makes it, Secrets Manager holds it, and the instance role above grants read on that
one ARN. The Worker's CodeDeploy `install.sh` fetches it at deploy time rather than having it
baked into userdata, an instance tag, or an onboarding URL in git.

`special = false` because the token is passed through a URL query string during Worker
onboarding, and it is not worth the escaping risk for 32 characters of alphanumeric entropy.

### Userdata (`userdata.sh`)

Runs once at first boot, as root, under `set -euxo pipefail`:

```bash
dnf install -y amazon-cloudwatch-agent git
id -u cribl >/dev/null 2>&1 || useradd -r -m -s /sbin/nologin cribl
```

**`git` is not incidental** — Cribl uses git internally for config versioning, and without the
binary present it fails at boot with an opaque "no versioning available" error. The `cribl`
service user is created here (idempotently) and again in the deploy hooks, so the ordering
between userdata and the first deployment does not matter.

Then it writes the CloudWatch agent config and starts the agent. The config publishes into a
custom `CriblStream` namespace:

- `cpu` (idle/user/system, `totalcpu`), `mem` (`mem_used_percent`), `disk` (`used_percent` on `/`)
- **`procstat`** matching the pattern `/opt/cribl/bin/cribl`, measurement `pid_count`, every 60s

That last one is the load-bearing metric. `procstat` counts processes whose command line
matches the pattern and publishes `procstat_lookup_pid_count` — **0 when `cribl.service` is
down**. That is the exact metric
[aws-notification-configuration](aws-notification-configuration.md) alarms on.

The subtlety, and the reason the config has an `aggregation_dimensions` block:

```json
"append_dimensions":      { "InstanceId": "${aws:InstanceId}" },
"aggregation_dimensions": [["InstanceId"]],
```

`procstat` tags its lookup metric with `pattern` and `pidfinder` dimensions *on top of*
`InstanceId`. A CloudWatch alarm has to match a metric's dimensions **exactly**, so without
this, every alarm would have to name all three — brittle, and it would break the moment the
pattern string changed. The `aggregation_dimensions` rollup publishes each metric a second
time keyed on `InstanceId` alone, so the alarms only match the one dimension they care about.

## Outputs

```hcl
output "instance_ids"          # { "leader-primary" = "i-0abc...", ... }
output "instance_private_ips"  # { "leader-primary" = "10.0.1.195", ... }
output "auth_token_secret_arn"
```

`instance_ids` is consumed by `aws-notification-configuration`, which `for_each`es over it to
build one alarm per instance — so a new instance in the `instances` map automatically gets an
alarm, with no change to the notification root.

`instance_private_ips` is exported but **not yet consumed**, which is exactly the gap behind
the hardcoded Leader IP in `deploy-workers/scripts/install.sh`. The value the Worker needs is
already right here.
