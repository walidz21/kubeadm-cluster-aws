# Outputs print values after apply, so you don't have to dig in the console.

output "control_plane_public_ip" {
  description = "SSH here first. This is where kubeadm init runs."
  value       = aws_instance.control_plane.public_ip
}

output "worker_public_ip" {
  description = "SSH here second. This is where kubeadm join runs."
  value       = aws_instance.worker.public_ip
}

output "control_plane_private_ip" {
  description = "The address the worker uses to reach the API server inside the VPC."
  value       = aws_instance.control_plane.private_ip
}

output "ssh_control_plane" {
  description = "Copy-paste SSH command for the control plane."
  value       = "ssh -i C:/Users/TRETEC/.ssh/k8s-lab ubuntu@${aws_instance.control_plane.public_ip}"
}

output "ssh_worker" {
  description = "Copy-paste SSH command for the worker."
  value       = "ssh -i C:/Users/TRETEC/.ssh/k8s-lab ubuntu@${aws_instance.worker.public_ip}"
}