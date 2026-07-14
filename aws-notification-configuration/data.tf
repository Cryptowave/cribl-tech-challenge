data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Instance names/IDs to alarm on - one alarm per instance, keyed by the same
# names terraform-app uses ("leader-primary", "worker", ...).
data "terraform_remote_state" "app" {
  backend = "s3"

  config = {
    bucket = "stream-state-minfanger-us-east-2"
    key    = "app/terraform.tfstate"
    region = "us-east-2"
  }
}
