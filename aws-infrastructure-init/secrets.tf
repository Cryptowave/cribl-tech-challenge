# Auth token shared by the Leader HA pair and every Worker for the
# distributed control channel (port 4200). Generated once here so it never
# has to be typed/committed anywhere; instances fetch it at boot via IAM
# (see iam.tf) instead of it being baked into userdata or instance tags.
resource "random_password" "auth_token" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "auth_token" {
  name        = "cribl-stream/distributed-auth-token"
  description = "Cribl Stream distributed mode auth token (leader<->worker)"
}

resource "aws_secretsmanager_secret_version" "auth_token" {
  secret_id     = aws_secretsmanager_secret.auth_token.id
  secret_string = random_password.auth_token.result
}
