output "zone_id" {
  description = "Route 53 hosted zone ID (looked up, not created)"
  value       = data.aws_route53_zone.this.zone_id
}

output "name_servers" {
  description = "Name servers for the hosted zone (for delegation checks)"
  value       = data.aws_route53_zone.this.name_servers
}

output "certificate_arn" {
  description = "ARN of the validated wildcard ACM certificate (*.{domain_name})"
  value       = aws_acm_certificate_validation.this.certificate_arn
}
