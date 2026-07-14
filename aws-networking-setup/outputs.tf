output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.cribl_stream.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.cribl_stream.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}
