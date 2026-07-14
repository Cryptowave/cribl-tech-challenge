output "instance_ids" {
  description = "IDs of the app EC2 instances"
  value       = { for name, inst in aws_instance.app : name => inst.id }
}

output "instance_private_ips" {
  description = "Private IPs of the app EC2 instances"
  value       = { for name, inst in aws_instance.app : name => inst.private_ip }
}

output "auth_token_secret_arn" {
  description = "Secrets Manager ARN holding the distributed mode auth token"
  value       = aws_secretsmanager_secret.auth_token.arn
}
