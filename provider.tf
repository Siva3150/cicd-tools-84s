terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.0.0"
    }
  }

  backend "s3" {
    bucket       = "84s-siva-remote-state-dev"
    key          = "roboshop-dev-cicd"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}




provider "aws" {
# Configuration options
  region = "us-east-1"
}