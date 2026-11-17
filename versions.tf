terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.49 is the first release with the AgentCore resources. 6.48 had a crash on refresh and the 6.4x line had a gateway delete-ordering bug, so the floor is higher.
      # Tested with 6.71 and 6.72. Commit the .terraform.lock.hcl of your own root module.
      version = ">= 6.55"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}
