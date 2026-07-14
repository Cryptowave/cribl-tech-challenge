variable "instance_type" {
  description = "EC2 instance type for the app instances"
  type        = string
  default     = "t3.medium"
}

variable "instances" {
  description = "Map of instance name to role (leader or worker)"
  type        = map(string)
  default = {
    "leader-primary" = "leader"
    "leader-passive" = "leader"
    "worker"         = "worker"
  }
}

variable "admin_cidr_blocks" {
  description = "CIDR blocks allowed to reach the Leader UI (port 9000). No default on purpose - must be set explicitly rather than left open."
  type        = list(string)
}
