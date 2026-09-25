# dns module — Route 53 hosted zone lookup and ACM certificate for the public domain.
#
# The hosted zone is looked up via a data source, not created as a resource.
# Route 53 already creates a hosted zone automatically when a domain is
# registered; creating a second one here would put the ACM DNS validation
# records in the wrong zone and the certificate would never validate.

data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

# Wildcard cert covers both the dev record (petclinic-dev.{domain}) and the
# prod record (petclinic.{domain}) — see technical-spec.md#dns-and-ingress.
resource "aws_acm_certificate" "this" {
  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-cert"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
