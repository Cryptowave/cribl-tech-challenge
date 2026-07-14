data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "notify" {
  name               = "${var.app_name}-service-down-notify-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "notify_logs" {
  role       = aws_iam_role.notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "notify_ses" {
  statement {
    actions = ["ses:SendEmail"]

    # SendEmail is authorized against an identity ARN per address involved, and
    # IAM matches those ARNs literally: the domain ARN does *not* stand in for
    # the addresses under it. So the From address needs its own ARN here even
    # though only the domain is verified, and the recipient needs one while it
    # is a verified identity of its own (the sandbox). Miss any and the call is
    # denied on the one that is missing. The From/To conditions, not the
    # resource list, are what keep this role to the single alert address.
    resources = concat(
      [
        aws_ses_domain_identity.sender.arn,
        "arn:aws:ses:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:identity/${var.alert_from_address}",
      ],
      aws_ses_email_identity.recipient[*].arn,
    )

    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.alert_from_address]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "ses:Recipients"
      values   = [var.alert_to_address]
    }
  }
}

resource "aws_iam_role_policy" "notify_ses" {
  name   = "${var.app_name}-service-down-notify-ses"
  role   = aws_iam_role.notify.id
  policy = data.aws_iam_policy_document.notify_ses.json
}
