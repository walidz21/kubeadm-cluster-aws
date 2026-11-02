# Variables let us change values without editing the main config.

variable "aws_region" {
  description = "AWS region. This account is restricted to eu-north-1 (Stockholm)."
  type        = string
  default     = "eu-north-1"
}

variable "availability_zone" {
  description = "Which datacenter inside the region. Both nodes share one so traffic between them is free and fast."
  type        = string
  default     = "eu-north-1a"
}

variable "instance_type" {
  description = "t3.medium = 2 vCPU, 4 GB RAM. kubeadm refuses to run below 2 CPU and 2 GB, so this is the realistic minimum."
  type        = string
  default     = "t3.medium"
}

variable "ssh_public_key_path" {
  description = "Path to the PUBLIC half of the SSH key pair."
  type        = string
  default     = "C:/Users/TRETEC/.ssh/k8s-lab.pub"
}

variable "project_name" {
  description = "Prefix for resource names, so everything is easy to find and delete."
  type        = string
  default     = "k8s-lab"
}
