output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_region" {
  description = "AWS region the cluster lives in."
  value       = var.region
}

output "cluster_endpoint" {
  description = "EKS control plane endpoint URL."
  value       = aws_eks_cluster.this.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded EKS cluster CA certificate."
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA role trust policies."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider backing IRSA."
  value       = aws_iam_openid_connect_provider.oidc.arn
}

output "node_role_arn" {
  description = "ARN of the least-privilege node IAM role."
  value       = aws_iam_role.node.arn
}

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs — use these for in-VPC workloads and future bastion."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs — NAT and public load balancers only."
  value       = aws_subnet.public[*].id
}

output "kms_key_arn" {
  description = "ARN of the KMS CMK used for EKS secrets envelope encryption."
  value       = aws_kms_key.eks.arn
}

output "kubectl_configure_command" {
  description = "Run this to populate ~/.kube/config for the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name}"
}
