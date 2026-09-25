# Backend values cannot reference variables, so the bucket name embeds the
# AWS account ID directly, matching what scripts/bootstrap-state.sh provisions.
# Run scripts/bootstrap-state.sh before the first `terraform init`.
terraform {
  backend "s3" {
    bucket         = "petclinic-terraform-state-771174261648"
    key            = "petclinic/dev/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "petclinic-terraform-locks"
    encrypt        = true
  }
}
