output "repository_urls" {
  description = "Map of service name to ECR repository URL ({account}.dkr.ecr.{region}.amazonaws.com/{project}-{env}/{service})"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  description = "Map of service name to ECR repository ARN"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.arn }
}
