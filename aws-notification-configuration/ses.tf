# Sender is verified at the domain level with Easy DKIM, so alerts@ does not
# need a real inbox - nothing has to click a confirmation link. The tradeoff is
# that SES will not send until the DNS records in `terraform output
# sender_dns_records` exist on the domain. Verification is asynchronous: the
# apply succeeds immediately and the identity sits unverified until the records
# resolve.
resource "aws_ses_domain_identity" "sender" {
  domain = var.sender_domain
}

resource "aws_ses_domain_dkim" "sender" {
  domain = aws_ses_domain_identity.sender.domain
}

# Deliberately not using aws_ses_domain_identity_verification: it blocks the
# apply polling SES for up to 45 minutes and fails the run if the DNS records
# are not in place yet, which they cannot be on a first apply.

# Sandbox accounts may only send to verified recipients, and a Gmail address
# can only be verified by clicking the link AWS emails to it. Harmless once the
# account has production access.
resource "aws_ses_email_identity" "recipient" {
  count = var.verify_recipient_identity ? 1 : 0

  email = var.alert_to_address
}
