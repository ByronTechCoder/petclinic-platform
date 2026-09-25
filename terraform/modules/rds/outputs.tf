output "endpoint" {
  description = "RDS endpoint hostname (host only — see the port output; combine as jdbc:mysql://{endpoint}:{port}/petclinic)"
  value       = aws_db_instance.this.address
}

output "port" {
  description = "RDS port (3306)"
  value       = aws_db_instance.this.port
}

output "db_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.this.id
}

output "secret_arn" {
  description = "Secrets Manager ARN for the RDS master credentials (for External Secrets Operator)"
  value       = aws_secretsmanager_secret.rds_credentials.arn
}

output "connection_string" {
  description = "JDBC connection string (credentials not included — pull those from secret_arn via ESO, per docs/database-initialization.md)"
  value       = "jdbc:mysql://${aws_db_instance.this.address}:${aws_db_instance.this.port}/petclinic"
}
