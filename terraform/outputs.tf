# ==============================================================================
# TERRAFORM OUTPUTS
# Values exported from the Terraform state after `terraform apply` completes.
# These are captured by the GitHub Actions pipeline using:
#   terraform output -raw <output_name>
# and written to $GITHUB_OUTPUT for use in downstream steps.
# ==============================================================================

# ------------------------------------------------------------------------------
# staging_instance_public_ip
# The public IPv4 address assigned to the EC2 instance at creation time.
# Used by:
#   - The health check loop to poll :8080/api/users
#   - The OWASP ZAP DAST scan as its target URL
#   - The verification window banner to display live endpoint addresses
# ------------------------------------------------------------------------------
output "staging_instance_public_ip" {
  description = "The public IP of the ephemeral staging application server"
  value       = aws_instance.app_server.public_ip
}

# ------------------------------------------------------------------------------
# staging_instance_id
# The unique AWS EC2 instance identifier (format: i-xxxxxxxxxxxxxxxxx).
# Used exclusively by the Telemetry Interceptor step (if: failure()) to call:
#   aws ec2 get-console-output --instance-id $INSTANCE_ID
# which dumps the complete cloud-init boot log to the Actions console for
# debugging, before the environment is destroyed.
# ------------------------------------------------------------------------------
output "staging_instance_id" {
  description = "The unique AWS instance ID for cloud telemetry extraction"
  value       = aws_instance.app_server.id
}