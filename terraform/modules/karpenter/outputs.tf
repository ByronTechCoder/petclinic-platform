output "karpenter_role_arn" {
  description = "Karpenter controller IRSA role ARN (annotate the karpenter ServiceAccount with this)"
  value       = aws_iam_role.controller.arn
}

output "karpenter_queue_name" {
  description = "SQS interruption queue name (Karpenter settings.interruptionQueue)"
  value       = aws_sqs_queue.interruption.name
}

output "karpenter_instance_profile_name" {
  description = "Instance profile for Karpenter-launched nodes (referenced by the EC2NodeClass)"
  value       = aws_iam_instance_profile.node.name
}
