resource "aws_instance" "app" {
  for_each = var.instances

  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type
  subnet_id     = data.terraform_remote_state.network.outputs.public_subnet_ids[0]
  vpc_security_group_ids = [
    each.value == "leader" ? aws_security_group.leader.id : aws_security_group.worker.id
  ]
  iam_instance_profile = aws_iam_instance_profile.ssm.name
  user_data            = file("${path.module}/userdata.sh")

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  tags = {
    Name        = each.key
    Application = "cribl-stream"
    Role        = each.value
  }
}
