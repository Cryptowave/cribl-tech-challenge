resource "aws_sns_topic" "service_down" {
  name = "${var.app_name}-service-down"
}

data "aws_iam_policy_document" "topic" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.service_down.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "service_down" {
  arn    = aws_sns_topic.service_down.arn
  policy = data.aws_iam_policy_document.topic.json
}

resource "aws_sns_topic_subscription" "notify" {
  topic_arn = aws_sns_topic.service_down.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.notify.arn
}
