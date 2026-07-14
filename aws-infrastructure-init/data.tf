data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "stream-state-minfanger-us-east-2"
    key    = "network/terraform.tfstate"
    region = "us-east-2"
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
