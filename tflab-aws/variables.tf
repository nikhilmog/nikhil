variable "participant_name" {
  description = "Participant name (lowercase, no spaces) — used in resource names"
  type        = string
}

variable "aws_region" {
  description = "AWS region — equivalent to Azure location (eastus → us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "public_key" {
  description = "SSH public key content for the EC2 key pair (used on Linux VMs). Generate with: ssh-keygen -t rsa -b 4096"
  type        = string
}

variable "admin_password" {
  description = "Admin password for the Windows VM labadmin user"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Password for the PostgreSQL labuser account on the DB VM"
  type        = string
  sensitive   = true
}
