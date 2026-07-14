resource "aws_codedeploy_app" "cribl" {
  name             = var.app_name
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "cribl" {
  app_name              = aws_codedeploy_app.cribl.name
  deployment_group_name = "${var.app_name}-instances"
  service_role_arn      = aws_iam_role.codedeploy_service.arn

  # Workers serve live traffic and there's no HA pairing between them like
  # the leaders, so still roll one at a time rather than all together.
  deployment_config_name = "CodeDeployDefault.OneAtATime"

  ec2_tag_filter {
    key   = var.deployment_group_tag.key
    type  = "KEY_AND_VALUE"
    value = var.deployment_group_tag.value
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}
