# Add these to the merleinfanger.com zone by hand - the domain is not managed
# by Route 53 in this repo, so Terraform cannot create the records itself. SES
# will not send from the domain until they resolve.
output "sender_dns_records" {
  description = "DNS records to publish for SES to verify the sender domain"
  value = {
    # Proves ownership of the domain to SES.
    verification_txt = {
      name  = "_amazonses.${aws_ses_domain_identity.sender.domain}"
      type  = "TXT"
      value = aws_ses_domain_identity.sender.verification_token
    }
    # Easy DKIM: three CNAMEs pointing at AWS-hosted keys, which let SES sign
    # outbound mail. Keep them in place - SES re-checks them, and pulling them
    # later revokes the verification.
    dkim_cnames = [
      for token in aws_ses_domain_dkim.sender.dkim_tokens : {
        name  = "${token}._domainkey.${aws_ses_domain_identity.sender.domain}"
        type  = "CNAME"
        value = "${token}.dkim.amazonses.com"
      }
    ]
  }
}

output "sns_topic_arn" {
  description = "SNS topic the service-down alarms publish to"
  value       = aws_sns_topic.service_down.arn
}

output "alarm_names" {
  description = "Service-down alarm per instance"
  value       = { for name, alarm in aws_cloudwatch_metric_alarm.service_down : name => alarm.alarm_name }
}

output "notify_function_name" {
  description = "Lambda that sends the SES alert"
  value       = aws_lambda_function.notify.function_name
}
