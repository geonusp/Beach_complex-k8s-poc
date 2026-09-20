output "instance_id" {
  description = "EC2 instance ID. SSM targets the node with this value."
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "EC2 private IPv4 address."
  value       = aws_instance.this.private_ip
}

output "public_ip" {
  description = "EC2 public IPv4 address."
  value       = aws_instance.this.public_ip
}
