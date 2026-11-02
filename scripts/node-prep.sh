#!/bin/bash
# Prepares a fresh Ubuntu node to be a Kubernetes node (control plane or worker).
# Safe to run more than once.

set -e   # stop immediately if any command fails, instead of carrying on broken

echo "=== 1. Swap off ==="
# kubelet refuses to start with swap on: the scheduler needs the real memory
# figure, and swap makes that number a lie.
sudo swapoff -a
# Comment out the swap line in fstab so it stays off across reboots.
sudo sed -i '/[[:space:]]swap[[:space:]]/ s/^[^#]/#&/' /etc/fstab

echo "=== 2. Kernel modules ==="
# overlay      = the layered filesystem containerd builds images with
# br_netfilter = lets iptables see traffic crossing a bridge, which is how
#                Service routing and pod networking actually function
sudo tee /etc/modules-load.d/k8s.conf > /dev/null <<'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

echo "=== 3. Network sysctls ==="
# bridge-nf-call-* makes iptables rules apply to bridged traffic.
# ip_forward lets the node route packets between pods.
# Without these, pods start but cannot reach each other.
sudo tee /etc/sysctl.d/k8s.conf > /dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system > /dev/null

echo "=== 4. containerd ==="
sudo apt-get update -qq
sudo apt-get install -y -qq containerd
# Ubuntu ships containerd with a stub config that has the CRI plugin DISABLED.
# Kubernetes talks to containerd over CRI, so replace the stub with the full
# default config, which has CRI enabled.
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
# THE CRITICAL LINE. Ubuntu manages cgroups with systemd and so does kubelet.
# If containerd uses the other driver, two things fight over the same cgroups
# and kubelet dies with an error that never mentions cgroups.
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "=== 5. Kubernetes packages (v1.36) ==="
sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
# Download the repo signing key and convert it to the binary format apt wants.
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
# Add the repo, telling apt which key signs it.
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq kubelet kubeadm kubectl
# "hold" stops apt upgrading these by accident. Kubernetes components must be
# upgraded deliberately, one minor version at a time, never by a routine
# apt upgrade.
sudo apt-mark hold kubelet kubeadm kubectl

echo ""
echo "=== Verification ==="
echo -n "cgroup driver: "; grep SystemdCgroup /etc/containerd/config.toml || echo "MISSING - STOP"
echo -n "containerd:    "; systemctl is-active containerd
echo -n "swap total:    "; free -h | awk '/Swap/ {print $2}'
echo -n "ip_forward:    "; sysctl -n net.ipv4.ip_forward
echo -n "bridge-nf:     "; sysctl -n net.bridge.bridge-nf-call-iptables
echo -n "kubeadm:       "; kubeadm version -o short
echo "=== Done ==="