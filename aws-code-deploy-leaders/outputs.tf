output "artifact_bucket_name" {
  description = "S3 bucket to upload CodeDeploy revision bundles to"
  value       = aws_s3_bucket.artifacts.bucket
}

output "codedeploy_application_name" {
  value = aws_codedeploy_app.cribl.name
}

output "codedeploy_deployment_group_name" {
  value = aws_codedeploy_deployment_group.cribl.deployment_group_name
}
