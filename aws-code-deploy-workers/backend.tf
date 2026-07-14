terraform {
  backend "s3" {
    bucket       = "stream-state-minfanger-us-east-2"
    key          = "deploy-worker/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
