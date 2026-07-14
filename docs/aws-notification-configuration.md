# `aws-notification-configuration/`

Monitoring and alerting: detect that Cribl has stopped running on any instance, and email a
human about it.

**State key:** `notifications/terraform.tfstate` · **Depends on:**
[aws-infrastructure-init](aws-infrastructure-init.md) (for the instance list *and* for the
CloudWatch agent that publishes the metric)

## The chain

```
CloudWatch agent (procstat)  →  procstat_lookup_pid_count metric
        │                            (published by userdata.sh on each host)
        ▼
CloudWatch alarm per instance   Minimum < 1 for 2×60s, missing data = breaching
        ▼
SNS topic  cribl-stream-service-down
        ▼
Lambda  cribl-stream-service-down-notify  (python3.12)
        ▼
SES  alerts@merleinfanger.com → merleinfanger@gmail.com
```

## Walkthrough

### `cloudwatch.tf` — one alarm per instance

The instance list is not written down here; it is read out of the compute layer's state
(`data.tf`) and iterated:

```hcl
locals {
  alarm_name_prefix = "${var.app_name}-service-down-"
  instance_ids      = data.terraform_remote_state.app.outputs.instance_ids
}

resource "aws_cloudwatch_metric_alarm" "service_down" {
  for_each = local.instance_ids

  alarm_name  = "${local.alarm_name_prefix}${each.key}"   # cribl-stream-service-down-leader-primary
  namespace   = "CriblStream"
  metric_name = "procstat_lookup_pid_count"
  dimensions  = { InstanceId = each.value }

  statistic           = "Minimum"
  period              = 60
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = var.datapoints_to_alarm   # 2
  datapoints_to_alarm = var.datapoints_to_alarm

  treat_missing_data = "breaching"
  alarm_actions      = [aws_sns_topic.service_down.arn]
}
```

Adding an instance to the `instances` map in `aws-infrastructure-init` gives it an alarm here
automatically — no edit to this file.

Four decisions worth spelling out:

**Why `procstat_lookup_pid_count`.** The CloudWatch agent's `procstat` plugin — configured in
[`aws-infrastructure-init/userdata.sh`](aws-infrastructure-init.md#userdata-userdatash) with
the pattern `/opt/cribl/bin/cribl` — counts matching processes and publishes the count. **It
publishes 0 when the service is down.** That is a direct signal about the thing we actually
care about (is Cribl running?), not a proxy like CPU or a port check.

**`Minimum`, not `Average`.** Over a 60s period, averaging would let a single dead datapoint
get diluted by live ones. `Minimum` means *any* datapoint at zero within the period counts as
down.

**`treat_missing_data = "breaching"`.** This is the important one. A host that is powered off,
wedged, or that has lost the CloudWatch agent publishes **nothing at all** — and with the
default handling that alarm sits in `INSUFFICIENT_DATA` forever, silently. But "the box is not
reporting" *is* an outage. Treating absent data as breaching means a dead host alarms exactly
like a dead process.

**Two datapoints, not one.** `datapoints_to_alarm = 2` over 60s periods rides out a CloudWatch
agent hiccup or a fast service restart (including one caused by a CodeDeploy deployment)
without emailing anyone. The cost is up to ~2 minutes of detection latency, which is the right
trade for an email alert.

### `sns.tf` — the topic

An SNS topic with a resource policy allowing `sns:Publish` from `cloudwatch.amazonaws.com`,
conditioned on `aws:SourceAccount` matching this account — so another account's CloudWatch
cannot publish into it. The topic is subscribed to by the Lambda (protocol `lambda`), and
`aws_lambda_permission` on the Lambda side allows invocation from that specific topic ARN.

SNS sits in the middle rather than the alarm emailing directly because **the alarm cannot send
a useful email on its own.** A raw SNS email subscription delivers the CloudWatch alarm JSON
blob. Routing through Lambda means the operator gets a readable message that names the host.
It also leaves an obvious extension point — adding PagerDuty or Slack is another subscriber on
the same topic, not a rewrite.

### `lambda.tf` + `lambda/notify.py` — turning an alarm into an email

`archive_file` zips `notify.py` at plan time and `source_code_hash` ties the function to its
contents, so editing the Python is enough to trigger a redeploy. Python 3.12, 10s timeout, and
three environment variables: `ALARM_NAME_PREFIX`, `FROM_ADDRESS`, `TO_ADDRESS`.

The log group is declared explicitly with 14-day retention and the function `depends_on` it:

```hcl
resource "aws_cloudwatch_log_group" "notify" {
  name              = "/aws/lambda/${var.app_name}-service-down-notify"
  retention_in_days = 14
}
```

Without that, the first invocation races Lambda's *implicit* log group creation, which lands
with **retention set to never expire** — logs accumulate forever and Terraform does not own the
group.

The function itself:

```python
def instance_name(alarm):
    name = alarm.get("AlarmName", "")
    if name.startswith(ALARM_NAME_PREFIX):
        return name[len(ALARM_NAME_PREFIX):]
    # fall back to the InstanceId dimension
    ...

def handler(event, _context):
    for record in event["Records"]:
        alarm = json.loads(record["Sns"]["Message"])

        if alarm.get("NewStateValue") != "ALARM":
            continue

        ses.send_email(...)
```

The instance name is recovered by **stripping the alarm-name prefix** — Terraform names each
alarm `<prefix><instance name>`, so the human-friendly name (`leader-primary`) is already sitting
right there, no `DescribeInstances` call and no extra IAM permission needed. The prefix is
passed in as an env var from the same `local` that builds the alarm names, so the two cannot
drift apart. If an alarm ever reaches the topic without the expected prefix, it falls back to
the `InstanceId` dimension so the email still says *which host* broke rather than dropping the
detail.

The `NewStateValue != "ALARM"` guard is defensive: the alarms only publish on `ALARM` today,
but if someone later adds an `ok_actions` or `insufficient_data_actions` to the same topic, it
must not send a "service has failed" email on recovery.

### `ses.tf` + `iam.tf` — email, and the DNS rabbit hole

**Domain-level verification with Easy DKIM.** `aws_ses_domain_identity` +
`aws_ses_domain_dkim` on `merleinfanger.com`, which means the sender
(`alerts@merleinfanger.com`) **needs no real inbox** — nothing has to click a confirmation
link for it. The trade-off is that SES will not send at all until the DNS records exist.

Verification is asynchronous: the `apply` succeeds immediately and the identity sits
unverified until the records resolve. `aws_ses_domain_identity_verification` is deliberately
**not** used — it blocks the apply polling SES for up to 45 minutes and then fails the run if
the records are not in place, which on a first apply they cannot be, because the records are an
*output* of that very apply.

So the records are exposed as an output to publish by hand:

```bash
terraform output sender_dns_records
```

- one **TXT** at `_amazonses.merleinfanger.com` — proves domain ownership
- three **CNAMEs** at `<token>._domainkey.merleinfanger.com` → `<token>.dkim.amazonses.com` —
  Easy DKIM, letting SES sign outbound mail

Leave them in place permanently; SES re-checks them, and removing them later revokes the
verification.

**The IAM policy is the fiddly part** (this is where the time went). `ses:SendEmail` is
authorized against an identity ARN **per address involved**, and IAM matches those ARNs
*literally* — the domain ARN does **not** stand in for the addresses under it. So the policy
has to list:

- the domain identity ARN,
- an ARN for the **From address itself** (`…:identity/alerts@merleinfanger.com`) — even though
  only the domain is verified,
- an ARN for the **recipient**, while it is a verified identity of its own (the sandbox).

Miss any one and the call is denied on precisely the one that is missing. What actually keeps
this role scoped to the single alert address is not the resource list but the two conditions:

```hcl
condition { test = "StringEquals",                variable = "ses:FromAddress", values = [var.alert_from_address] }
condition { test = "ForAllValues:StringEquals",   variable = "ses:Recipients",  values = [var.alert_to_address] }
```

**The sandbox.** A new SES account may only send to *verified recipients*, and a Gmail address
can only be verified by clicking a link AWS emails to it. `verify_recipient_identity` (default
`true`) creates that `aws_ses_email_identity` so you get the link. Set it to `false` once the
account has production access.

## Usage

```bash
cd aws-notification-configuration
terraform init
terraform apply
terraform output sender_dns_records   # then publish these on the domain
```

**The DNS step is optional if CloudWatch monitoring on its own is sufficient.** The alarms, the
SNS topic, and the Lambda all deploy and function regardless — alarms will fire and be visible
in the console. Only the final email leg depends on the DNS records resolving.

## Outputs

| Output | Use |
| --- | --- |
| `sender_dns_records` | The TXT + 3 DKIM CNAMEs to publish on the domain |
| `sns_topic_arn` | Attach further subscribers (PagerDuty, Slack, …) |
| `alarm_names` | Per-instance alarm names |
| `notify_function_name` | For tailing the Lambda's logs |

## Testing it

SSH/SSM onto a host and `systemctl stop cribl`. Within ~2 minutes `procstat_lookup_pid_count`
drops to 0, the alarm transitions to `ALARM`, and the email arrives naming that host. The body
is deliberately terse and points at the runbook:

> *please refer to recovery workbook in repository, service on `<name>` has failed*
