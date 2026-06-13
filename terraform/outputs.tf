output "staging_instance_public_ip" {
  description = "The public IP of the ephemeral staging application server"
  value       = aws_instance.app_server.public_ip
}

output "staging_instance_id" {
  description = "The unique AWS instance ID for cloud telemetry extraction"
  value       = aws_instance.app_server.id
}