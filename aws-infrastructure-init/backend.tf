terraform {
  backend "s3" {
    bucket         = "stream-state-minfanger-us-east-2" 
    key            = "app/terraform.tfstate"    
    region         = "us-east-2"                       
    encrypt        = true                              
    use_lockfile  = true                              
  }
}
