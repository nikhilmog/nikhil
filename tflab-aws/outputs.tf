output "vm_app_private_ip" {
  description = "Private IP of the app VM"
  value       = aws_instance.app.private_ip
}

output "vm_db_private_ip" {
  description = "Private IP of the DB VM"
  value       = aws_instance.db.private_ip
}

output "vm_win_private_ip" {
  description = "Private IP of the Windows VM"
  value       = aws_instance.win.private_ip
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket (equivalent to Azure Storage Account)"
  value       = aws_s3_bucket.lab.bucket
}

output "eic_endpoint_id" {
  description = "EC2 Instance Connect Endpoint ID (equivalent to Azure Bastion)"
  value       = aws_ec2_instance_connect_endpoint.lab.id
}

output "ssh_command_app" {
  description = "SSH to app VM via EIC endpoint (no public IP needed)"
  value       = "aws ec2-instance-connect ssh --instance-id ${aws_instance.app.id} --os-user labadmin"
}

output "ssh_command_db" {
  description = "SSH to DB VM via EIC endpoint"
  value       = "aws ec2-instance-connect ssh --instance-id ${aws_instance.db.id} --os-user labadmin"
}

output "rdp_tunnel_command" {
  description = "Open RDP tunnel to Windows VM via EIC endpoint, then RDP to localhost:13389"
  value       = "aws ec2-instance-connect open-tunnel --instance-id ${aws_instance.win.id} --remote-port 3389 --local-port 13389"
}

output "key_pair_name" {
  description = "EC2 key pair name"
  value       = aws_key_pair.lab.key_name
}
