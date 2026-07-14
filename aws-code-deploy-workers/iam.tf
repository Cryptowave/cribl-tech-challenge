# CodeDeploy service role - lets the CodeDeploy service itself call EC2/ASG/ELB APIs
data "aws_iam_policy_document" "codedeploy_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy_service" {
  name               = "${var.app_name}-codedeploy-service-role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume_role.json
}

resource "aws_iam_role_policy_attachment" "codedeploy_service" {
  role       = aws_iam_role.codedeploy_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# Existing EC2 instance role (created in terraform-app) needs to read the
# revision bundle from S3 - the CodeDeploy agent on each host does this.
data "aws_iam_role" "instance" {
  name = var.instance_role_name
}

data "aws_iam_policy_document" "artifact_bucket_read" {
  statement {
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
  }
}

resource "aws_iam_role_policy" "instance_artifact_bucket_read" {
  name   = "${var.app_name}-codedeploy-artifact-read"
  role   = data.aws_iam_role.instance.name
  policy = data.aws_iam_policy_document.artifact_bucket_read.json
}
