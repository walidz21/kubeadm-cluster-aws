output "control_plane_public_ip" {
  description = "Where kubeadm init runs."
  value       = aws_instance.control_plane.public_ip
}

output "worker_public_ip" {
  description = "Where kubeadm join runs."
  value       = aws_instance.worker.public_ip
}

output "control_plane_private_ip" {
  description = "The address the worker uses to reach the API server inside the VPC."
  value       = aws_instance.control_plane.private_ip
}

output "allowed_source_ip" {
  description = "The public IP permitted through the security group, as detected at apply time."
  value       = local.my_ip_cidr
}

output "ssh_control_plane" {
  value = "ssh -i ~/.ssh/k8s-lab ubuntu@${aws_instance.control_plane.public_ip}"
}

output "ssh_worker" {
  value = "ssh -i ~/.ssh/k8s-lab ubuntu@${aws_instance.worker.public_ip}"
}
