terraform {
  required_version = ">= 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.17.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket         = "ai-qa-assessment"
    key            = "ai-qa/dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}