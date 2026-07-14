data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm" {
  name               = "cribl-stream-app-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "cribl-stream-app-ssm-profile"
  role = aws_iam_role.ssm.name
}

# Lets configure.sh on each instance read its own Role tag and fetch the
# distributed auth token.
data "aws_iam_policy_document" "instance_extra" {
  statement {
    actions   = ["ec2:DescribeTags"]
    resources = ["*"]
  }

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.auth_token.arn]
  }
}

resource "aws_iam_role_policy" "instance_extra" {
  name   = "cribl-stream-app-instance-extra"
  role   = aws_iam_role.ssm.name
  policy = data.aws_iam_policy_document.instance_extra.json
}
