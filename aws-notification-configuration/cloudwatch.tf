locals {
  # The Lambda recovers the instance name by stripping this prefix off the
  # alarm name, so the two must agree. Keep them in sync via the env var in
  # lambda.tf rather than hardcoding the string in the function.
  alarm_name_prefix = "${var.app_name}-service-down-"

  instance_ids = data.terraform_remote_state.app.outputs.instance_ids
}

resource "aws_cloudwatch_metric_alarm" "service_down" {
  for_each = local.instance_ids

  alarm_name        = "${local.alarm_name_prefix}${each.key}"
  alarm_description = "cribl.service is not running on ${each.key} (${each.value})."

  namespace   = "CriblStream"
  metric_name = "procstat_lookup_pid_count"
  dimensions = {
    InstanceId = each.value
  }

  # pid_count drops to 0 when no process matches, so anything under 1 is "the
  # service is down". Minimum, not Average, so a single dead datapoint in the
  # period still trips it.
  statistic           = "Minimum"
  period              = 60
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = var.datapoints_to_alarm
  datapoints_to_alarm = var.datapoints_to_alarm

  # A host that is off, wedged, or has lost the CloudWatch agent publishes
  # nothing at all - that is an outage too, so absent data has to alarm rather
  # than sit in INSUFFICIENT_DATA forever.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.service_down.arn]
}
