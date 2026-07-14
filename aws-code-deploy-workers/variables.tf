variable "app_name" {
  description = "Name used for the CodeDeploy application and related resources"
  type        = string
  default     = "cribl-stream-worker"
}

variable "artifact_bucket_name" {
  description = "Name of the S3 bucket that holds CodeDeploy revision bundles"
  type        = string
  default     = "cribl-deploy-artifacts-minfanger-worker-us-east-2"
}

variable "instance_role_name" {
  description = "Name of the existing EC2 instance IAM role (from terraform-app) that needs S3 read access to the artifact bucket"
  type        = string
  default     = "cribl-stream-app-ssm-role"
}

variable "deployment_group_tag" {
  description = "EC2 tag used to select instances for the CodeDeploy deployment group and SSM agent install"
  type = object({
    key   = string
    value = string
  })
  default = {
    key   = "Role"
    value = "worker"
  }
}
