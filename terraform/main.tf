# ---------- Providers ----------
# Versions are pinned so a future provider release cannot silently change
# behaviour.

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

# ---------- Current public IP ----------
# A home connection gets a new public IP regularly, and every change breaks SSH
# and kubectl until the firewall is updated. Looking the address up here means
# "terraform apply" alone repairs it: no variable to pass, no file to edit.
#
# Trade-off: this puts a network call in the plan phase, which is deliberately
# avoided in production configs because the plan then depends on an external
# service being reachable. Acceptable for a lab whose whole purpose is to be
# rebuilt often.
data "http" "my_ip" {
  url = "https://ipv4.icanhazip.com"
}

locals {
  # chomp strips the trailing newline the service returns.
  # /32 restricts the rule to this one address and nothing else.
  my_ip_cidr = "${chomp(data.http.my_ip.response_body)}/32"
}

# ---------- Network ----------

# A VPC is a private network inside AWS. 10.0.0.0/16 gives 65k addresses.
# It must NOT overlap the pod network given to Kubernetes later: Flannel uses
# 10.244.0.0/16, which sits outside this range.
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_name}-vpc" }
}

# An internet gateway is what lets the VPC reach the public internet. Without
# it the nodes cannot download containerd, kubeadm or any container image.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

# A subnet is a slice of the VPC inside one availability zone.
# map_public_ip_on_launch gives each instance a public IP automatically.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-subnet" }
}

# A route table decides where traffic goes. This one sends everything that is
# not local out through the internet gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-rt" }
}

# The route table does nothing until it is attached to the subnet.
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------- Firewall ----------

resource "aws_security_group" "nodes" {
  name        = "${var.project_name}-sg"
  description = "Firewall for the Kubernetes nodes"
  vpc_id      = aws_vpc.main.id

  # SSH, only from the current public IP.
  ingress {
    description = "SSH from my connection"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  # The Kubernetes API server, so kubectl works from outside the VPC.
  ingress {
    description = "Kubernetes API from my connection"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  # NodePort range, so a Service can be opened in a browser.
  ingress {
    description = "NodePort services from my connection"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  # THE IMPORTANT ONE. self = true allows all traffic between instances that
  # share this security group, which covers every port Kubernetes needs
  # internally in a single rule instead of a dozen: 6443 API, 2379-2380 etcd,
  # 10250 kubelet, 10257 and 10259 controller-manager and scheduler, and
  # 8472/UDP for Flannel's VXLAN overlay.
  ingress {
    description = "All traffic between cluster nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Outbound: unrestricted, so nodes can pull packages and images.
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg" }
}

# ---------- SSH key ----------
# Uploads the PUBLIC key to AWS so it is installed on both instances. The
# private key never leaves the machine.
resource "aws_key_pair" "main" {
  key_name   = "${var.project_name}-key"
  public_key = file(var.ssh_public_key_path)
}

# ---------- Base image ----------
# A data source reads something that already exists rather than creating it.
# This finds the newest official Ubuntu 22.04 image. Owner 099720109477 is
# Canonical, so we never accidentally boot somebody else's image.
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

# ---------- The two nodes ----------
# The Role tag is what the Ansible dynamic inventory groups on, so these
# values and the playbook's group names have to stay in step.

resource "aws_instance" "control_plane" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.main.key_name

  root_block_device {
    volume_size = 20 # GB. Container images fill 8 GB quickly.
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
