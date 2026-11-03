terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------- Source IP ----------

# A home connection gets a new public address regularly, and every change
# silently breaks SSH and the API server. Resolving it at plan time means
# "terraform apply" alone repairs the firewall.
#
# Trade-off: this puts a network call in the plan phase, which a production
# configuration would avoid, since the plan then depends on an external
# service. Acceptable for infrastructure meant to be rebuilt often.
data "http" "my_ip" {
  url = "https://ipv4.icanhazip.com"
}

locals {
  # chomp strips the trailing newline. /32 restricts the rule to one address.
  my_ip_cidr = "${chomp(data.http.my_ip.response_body)}/32"
}

# ---------- Network ----------

# Must not overlap the pod network given to Kubernetes later: Flannel uses
# 10.244.0.0/16, outside this range.
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------- Firewall ----------

resource "aws_security_group" "nodes" {
  name        = "${var.project_name}-sg"
  description = "Firewall for the Kubernetes nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my connection"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  ingress {
    description = "Kubernetes API from my connection"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  ingress {
    description = "NodePort services from my connection"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  # Covers every port Kubernetes needs internally in one rule instead of a
  # dozen: 6443 API, 2379-2380 etcd, 10250 kubelet, 10257 and 10259
  # controller-manager and scheduler, 8472/UDP for Flannel's VXLAN overlay.
  ingress {
    description = "All traffic between cluster nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg" }
}

# ---------- Instances ----------

resource "aws_key_pair" "main" {
  key_name   = "${var.project_name}-key"
  public_key = file(var.ssh_public_key_path)
}

# Owner 099720109477 is Canonical, so a third party cannot publish an image
# that matches this filter.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# The Role tag is what the Ansible dynamic inventory groups on, so these values
# and the playbook's group names are a contract between the two layers.

resource "aws_instance" "control_plane" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.main.key_name

  root_block_device {
    volume_size = 20 # container images fill 8 GB quickly
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.project_name}-control-plane"
    Role = "control-plane"
  }
}

resource "aws_instance" "worker" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.main.key_name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.project_name}-worker"
    Role = "worker"
  }
}
