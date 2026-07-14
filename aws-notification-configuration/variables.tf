variable "app_name" {
  description = "Name prefix for the notification resources"
  type        = string
  default     = "cribl-stream"
}

variable "sender_domain" {
  description = "Domain verified in SES with Easy DKIM. The alert sender must be an address on this domain."
  type        = string
  default     = "merleinfanger.com"
}

variable "alert_from_address" {
  description = "Sender for the alert email. Must be an address on sender_domain - it needs no inbox of its own, since the domain is what SES verifies."
  type        = string
  default     = "alerts@merleinfanger.com"

  validation {
    condition     = endswith(var.alert_from_address, "@${var.sender_domain}")
    error_message = "alert_from_address must be an address on sender_domain, or SES will refuse to send as it."
  }
}

variable "alert_to_address" {
  description = "Recipient of the alert email"
  type        = string
  default     = "merleinfanger@gmail.com"
}

variable "verify_recipient_identity" {
  description = "Create an SES identity for alert_to_address. Required while the SES account is in the sandbox, which only permits sending to verified recipients. Set to false once the account has production access."
  type        = bool
  default     = true
}

variable "datapoints_to_alarm" {
  description = "Number of consecutive 60s periods with the cribl process absent before the alarm fires. Two periods rides out an agent hiccup or a fast service restart without emailing."
  type        = number
  default     = 2
}
