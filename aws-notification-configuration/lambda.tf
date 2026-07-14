data "archive_file" "notify" {
  type        = "zip"
  source_file = "${path.module}/lambda/notify.py"
  output_path = "${path.module}/lambda/notify.zip"
}

resource "aws_lambda_function" "notify" {
  function_name = "${var.app_name}-service-down-notify"
  role          = aws_iam_role.notify.arn

  filename         = data.archive_file.notify.output_path
  source_code_hash = data.archive_file.notify.output_base64sha256
  handler          = "notify.handler"
  runtime          = "python3.12"
  timeout          = 10

  environment {
    variables = {
      ALARM_NAME_PREFIX = local.alarm_name_prefix
      FROM_ADDRESS      = var.alert_from_address
      TO_ADDRESS        = var.alert_to_address
    }
  }

  # Without this the first invocation races Lambda's implicit log group
  # creation, which lands with no retention set.
  depends_on = [aws_cloudwatch_log_group.notify]
}

resource "aws_cloudwatch_log_group" "notify" {
  name              = "/aws/lambda/${var.app_name}-service-down-notify"
  retention_in_days = 14
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notify.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.service_down.arn
}
