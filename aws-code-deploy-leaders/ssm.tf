# Installs and keeps the CodeDeploy agent up to date on every instance
# tagged for this application. Runs via the existing SSM managed-instance
# role (AmazonSSMManagedInstanceCore) already attached in terraform-app.
resource "aws_ssm_association" "codedeploy_agent" {
  name = "AWS-ConfigureAWSPackage"

  parameters = {
    action = "Install"
    name   = "AWSCodeDeployAgent"
  }

  targets {
    key    = "tag:${var.deployment_group_tag.key}"
    values = [var.deployment_group_tag.value]
  }

  schedule_expression = "rate(30 days)"
}
