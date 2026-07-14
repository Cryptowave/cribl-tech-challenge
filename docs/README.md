# Documentation

Code walkthroughs for each Terraform root and CodeDeploy bundle in this repo. Start with the
[top-level readme](../readme.md) for pre-requisites and the deployment order.

| Doc | Covers |
| --- | --- |
| [aws-networking-setup](aws-networking-setup.md) | VPC, subnets, IGW, routing |
| [aws-infrastructure-init](aws-infrastructure-init.md) | EC2 instances, security groups, IAM, Secrets Manager, userdata / CloudWatch agent |
| [aws-code-deploy-leaders](aws-code-deploy-leaders.md) | Leader CodeDeploy pipeline + the `deploy-leaders/` revision bundle |
| [aws-code-deploy-workers](aws-code-deploy-workers.md) | Worker CodeDeploy pipeline + the `deploy-workers/` revision bundle |
| [aws-notification-configuration](aws-notification-configuration.md) | CloudWatch alarms, SNS, Lambda, SES email alerts |

## How the layers fit together

```
aws-networking-setup          state key: network/terraform.tfstate
  └─ outputs: vpc_id, public_subnet_ids
       │  (read via terraform_remote_state)
       ▼
aws-infrastructure-init       state key: app/terraform.tfstate
  ├─ 3 EC2 instances tagged Role=leader | Role=worker
  ├─ security groups, SSM instance role, Secrets Manager auth token
  ├─ userdata: git + CloudWatch agent (procstat on /opt/cribl/bin/cribl)
  └─ outputs: instance_ids, instance_private_ips, auth_token_secret_arn
       │                                    │
       │ (targets Role tag)                 │ (read via terraform_remote_state)
       ▼                                    ▼
aws-code-deploy-leaders    aws-code-deploy-workers    aws-notification-configuration
  deploy-leaders/./deploy.sh   deploy-workers/./deploy.sh    alarms → SNS → Lambda → SES
```

The layers are deliberately separate Terraform roots with separate state keys. Networking
changes rarely, compute changes occasionally, and the delivery pipeline changes on its own
cadence — keeping them apart means a `terraform apply` on one never has to plan the others,
and a mistake in one cannot corrupt the state of another. They are coupled only by
`terraform_remote_state` reads and by the `Role` EC2 tag.

## Design decisions worth calling out

**The `Role` tag is the contract.** `aws-infrastructure-init` tags each instance
`Role=leader` or `Role=worker`. Both CodeDeploy roots select their targets with an
`ec2_tag_filter` on that tag, and both SSM associations install the CodeDeploy agent by
targeting the same tag. Nothing is selected by instance ID, so instances can be replaced
without touching the pipeline roots.

**The auth token never appears in code.** `random_password` generates it, Secrets Manager
holds it, and the instance role grants exactly `secretsmanager:GetSecretValue` on that one
secret ARN. The Worker's `install.sh` fetches it at deploy time. It is never in userdata, in
an instance tag, in git, or in a log — the `set +x` around the `curl` in `install.sh` exists
specifically to keep `set -x` from printing it in cleartext.

**Security groups reference security groups.** The Leader SG allows port 4200 from *the
Worker SG*, not from a CIDR. Adding a Worker changes nothing; the rule is about identity, not
address.

**Deployments roll one host at a time.** `CodeDeployDefault.OneAtATime` with auto-rollback on
`DEPLOYMENT_FAILURE`. The two Leaders are an HA pair — taking them both down at once defeats
the point of having two.

## Known limitations

These are the things I would fix next, in order.

1. **The Leader IP is hardcoded in the Worker install hook.**
   `deploy-workers/scripts/install.sh` curls `http://10.0.1.195:9000/init/install-worker.sh`.
   Rebuilding `leader-primary` gives it a new private IP and this must be edited by hand — it
   bit me once during this build. The fix is to look the Leader up at deploy time (its private
   IP is already an output of `aws-infrastructure-init`, or it can be resolved from the `Name`
   tag via `ec2:DescribeInstances`), or to front the Leader pair with an internal NLB so the
   Workers point at a stable endpoint.

2. **Leader failover still needs a human.** `leader-primary` and `leader-passive` both run
   under `resiliency: failover`, but the Workers are onboarded against the primary's address.
   True hands-off failover wants that stable endpoint from (1).

3. **Everything is in public subnets.** Fine for a challenge with the UI locked to
   `admin_cidr_blocks`, but a production build puts the Workers and the Leader HA pair in
   private subnets behind a NAT gateway, with the UI reached via a bastion or an ALB.

4. **SES is likely still in the sandbox.** That is why `verify_recipient_identity` exists.
   Request production access and set it to `false`.
