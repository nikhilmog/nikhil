terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─── Data Sources ─────────────────────────────────────────────────────────────

# Ubuntu 22.04 LTS (Canonical)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Windows Server 2022 (Amazon)
data "aws_ami" "windows_2022" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name  = "vpc-ailab"
    owner = "sathish"
  }
}

# ─── Internet Gateway ─────────────────────────────────────────────────────────

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name  = "igw-ailab"
    owner = "sathish"
  }
}

# ─── Subnets ──────────────────────────────────────────────────────────────────

# Public subnet: mirrors the Azure bastion subnet CIDR (10.0.3.0/27)
# Hosts the NAT Gateway and EIC Endpoint
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.3.0/27"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name  = "snet-public"
    owner = "sathish"
  }
}

# Private app subnet — equivalent to Azure snet-app
resource "aws_subnet" "app" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name  = "snet-app"
    owner = "sathish"
  }
}

# Private DB subnet — equivalent to Azure snet-db
resource "aws_subnet" "db" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name  = "snet-db"
    owner = "sathish"
  }
}

# ─── NAT Gateway ──────────────────────────────────────────────────────────────
# Required so private instances can reach the internet for package installs

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name  = "eip-nat-ailab"
    owner = "sathish"
  }
}

resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name  = "nat-ailab"
    owner = "sathish"
  }

  depends_on = [aws_internet_gateway.lab]
}

# ─── Route Tables ─────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = {
    Name  = "rt-public"
    owner = "sathish"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab.id
  }

  tags = {
    Name  = "rt-private"
    owner = "sathish"
  }
}

resource "aws_route_table_association" "app" {
  subnet_id      = aws_subnet.app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  subnet_id      = aws_subnet.db.id
  route_table_id = aws_route_table.private.id
}

# ─── Security Groups ──────────────────────────────────────────────────────────
# Equivalent to Azure NSGs, but using SG-to-SG references for EIC traffic

# EIC Endpoint SG — controls what the endpoint can reach outbound
resource "aws_security_group" "eic" {
  name        = "sg-eic"
  description = "EC2 Instance Connect Endpoint outbound rules"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "SSH to app and db subnets"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24", "10.0.2.0/24"]
  }

  egress {
    description = "RDP to app subnet (Windows VM)"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"]
  }

  tags = {
    Name  = "sg-eic"
    owner = "sathish"
  }
}

# App SG — equivalent to Azure nsg-app
# NOTE: intentional security issue preserved from original (RDP allowed alongside SSH)
resource "aws_security_group" "app" {
  name        = "sg-app"
  description = "App tier - SSH and RDP from EIC endpoint"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description     = "SSH from EIC endpoint"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eic.id]
  }

  ingress {
    description     = "RDP from EIC endpoint"
    from_port       = 3389
    to_port         = 3389
    protocol        = "tcp"
    security_groups = [aws_security_group.eic.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name  = "sg-app"
    owner = "sathish"
  }
}

# DB SG — equivalent to Azure nsg-db
resource "aws_security_group" "db" {
  name        = "sg-db"
  description = "DB tier - PostgreSQL from app tier, SSH from EIC"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description     = "SSH from EIC endpoint"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eic.id]
  }

  ingress {
    description     = "PostgreSQL from app tier"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name  = "sg-db"
    owner = "sathish"
  }
}

# ─── EC2 Key Pair ─────────────────────────────────────────────────────────────
# Replaces Azure password authentication for Linux VMs

resource "aws_key_pair" "lab" {
  key_name   = "kp-ailab-${var.participant_name}"
  public_key = var.public_key

  tags = {
    owner = "sathish"
  }
}

# ─── EC2 Instances ────────────────────────────────────────────────────────────

# App VM — equivalent to Azure vm-app (Standard_B2ms → t3.large: 2 vCPU, 8 GB)
resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large"
  subnet_id              = aws_subnet.app.id
  private_ip             = "10.0.1.10"
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = templatefile("${path.module}/cloud-init-app.yaml", {
    ssh_public_key = var.public_key
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
  }

  tags = {
    Name  = "vm-app"
    owner = "sathish"
  }
}

# DB VM — equivalent to Azure vm-db (Standard_B2ms → t3.large: 2 vCPU, 8 GB)
resource "aws_instance" "db" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large"
  subnet_id              = aws_subnet.db.id
  private_ip             = "10.0.2.10"
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.db.id]

  user_data = templatefile("${path.module}/cloud-init-db.yaml", {
    ssh_public_key = var.public_key
    db_password    = var.db_password
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
  }

  tags = {
    Name  = "vm-db"
    owner = "sathish"
  }
}

# Windows VM — equivalent to Azure vm-win (Standard_B2s → t3.medium: 2 vCPU, 4 GB)
resource "aws_instance" "win" {
  ami                    = data.aws_ami.windows_2022.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.app.id
  private_ip             = "10.0.1.20"
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.app.id]
  get_password_data      = true

  user_data = templatefile("${path.module}/cloud-init-win.ps1", {
    admin_password = var.admin_password
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 128
    delete_on_termination = true
  }

  tags = {
    Name  = "vm-win"
    owner = "sathish"
  }
}

# ─── EC2 Instance Connect Endpoint ────────────────────────────────────────────
# Equivalent to Azure Bastion — managed, no bastion EC2 required.
# preserve_client_ip = false so SG-to-SG rules work (source IP is EIC's ENI, not client IP)

resource "aws_ec2_instance_connect_endpoint" "lab" {
  subnet_id          = aws_subnet.app.id
  security_group_ids = [aws_security_group.eic.id]
  preserve_client_ip = false

  tags = {
    Name  = "eice-ailab"
    owner = "sathish"
  }
}

# ─── S3 Bucket ────────────────────────────────────────────────────────────────
# Equivalent to Azure Storage Account (StorageV2, Hot, LRS)

resource "aws_s3_bucket" "lab" {
  bucket = "s3-ailab-${var.participant_name}"

  tags = {
    owner = "sathish"
  }
}

resource "aws_s3_bucket_versioning" "lab" {
  bucket = aws_s3_bucket.lab.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Expire noncurrent versions after 30 days — mirrors Azure delete_retention_policy
resource "aws_s3_bucket_lifecycle_configuration" "lab" {
  bucket = aws_s3_bucket.lab.id

  depends_on = [aws_s3_bucket_versioning.lab]

  rule {
    id     = "noncurrent-version-expiry"
    status = "Enabled"

    filter {
      prefix = ""
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Block all public access — equivalent to Azure default private storage
resource "aws_s3_bucket_public_access_block" "lab" {
  bucket                  = aws_s3_bucket.lab.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
