variable "aws_region" {
  description = "AWS region. This account is restricted to eu-north-1."
  type        = string
  default     = "eu-north-1"
}

variable "availability_zone" {
  description = "Both nodes share one AZ so traffic between them is free and fast."
  type        = string
  default     = "eu-north-1a"
}

variable "instance_type" {
  description = "kubeadm refuses to run below 2 CPU and 2 GB, so t3.medium is the realistic minimum."
  type        = string
  default     = "t3.medium"
}

variable "ssh_public_key_path" {
  description = "Path to the public half of the SSH key pair."
  type        = string
  default     = "C:/Users/TRETEC/.ssh/k8s-lab.pub"
}

variable "project_name" {
  description = "Prefix for resource names."
  type        = string
  default     = "k8s-lab"
}
