resource "aws_security_group" "leader" {
  name        = "cribl-stream-leader"
  description = "Security group for Cribl Stream leader nodes"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    description = "UI access from admin CIDRs only"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = var.admin_cidr_blocks
  }

  ingress {
    description     = "Worker to leader: heartbeat/metrics/leader requests and config bundle downloads"
    from_port       = 4200
    to_port         = 4200
    protocol        = "tcp"
    security_groups = [aws_security_group.worker.id]
  }

  ingress {
    description     = "Worker to leader: UI/API access on port 9000"
    from_port       = 9000
    to_port         = 9000
    protocol        = "tcp"
    security_groups = [aws_security_group.worker.id]
  }

  ingress {
    description = "Leader-to-leader: distributed API traffic between leader-primary and leader-passive (both run cribl continuously under resiliency:failover)"
    from_port   = 4200
    to_port     = 4200
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Allow all outbound (required for SSM)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "cribl-stream-leader"
  }
}

resource "aws_security_group" "worker" {
  name        = "cribl-stream-worker"
  description = "Security group for Cribl Stream worker nodes"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  egress {
    description = "Allow all outbound (required for SSM and leader communication)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "cribl-stream-worker"
  }
}
