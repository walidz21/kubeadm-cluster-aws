# Kubernetes cluster on AWS with kubeadm

A two-node Kubernetes cluster built on AWS without a managed control plane. Terraform
provisions the infrastructure, kubeadm bootstraps the cluster, Flannel handles pod networking.

**Stack:** Kubernetes (kubeadm), Terraform, AWS EC2, containerd, Flannel, Ubuntu

---

## Architecture

```
┌─────────────────── VPC 10.0.0.0/16 ────────────────────┐
│                                                        │
│   Public subnet 10.0.1.0/24 (eu-north-1a)              │
│                                                        │
│   ┌──────────────────┐      ┌──────────────────┐       │
│   │  control-plane   │      │     worker       │       │
│   │  t3.medium       │◄────►│  t3.medium       │       │
│   │                  │      │                  │       │
│   │  kube-apiserver  │      │  kubelet         │       │
│   │  etcd            │      │  kube-proxy      │       │
│   │  scheduler       │      │  containerd      │       │
│   │  controller-mgr  │      │                  │       │
│   └──────────────────┘      └──────────────────┘       │
│            │                                           │
└────────────┼───────────────────────────────────────────┘
             │ 22, 6443, 30000-32767 restricted to one source IP
             ▼
     internet gateway
```

- Kubernetes v1.36.6
- containerd 2.2.1, systemd cgroup driver
- Flannel CNI, VXLAN overlay, pod network 10.244.0.0/16
- Ubuntu 22.04 LTS

---

## Repository layout

```
.
├── terraform/              # AWS layer: VPC, subnet, security group, two EC2 instances
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── scripts/
│   └── node-prep.sh        # swap, kernel modules, sysctl, containerd, kubeadm packages
└── README.md
```

Terraform covers the AWS layer only. The cluster itself is bootstrapped with kubeadm against
the prepared nodes, so the two concerns stay separate.

---

## How it was built

**1. AWS layer, Terraform.** A VPC with a public subnet, internet gateway and route table,
plus a security group that exposes SSH, the Kubernetes API and the NodePort range to a single
source IP while allowing unrestricted traffic between cluster members. Two t3.medium
instances with 20 GB gp3 root volumes.

**2. Node preparation.** Both nodes are brought to a state kubeadm will accept: swap disabled
permanently, the `overlay` and `br_netfilter` kernel modules loaded, IP forwarding and bridge
netfilter enabled via sysctl, containerd installed and reconfigured onto the systemd cgroup
driver, and the Kubernetes apt repository added with the packages version-locked. Scripted so
both nodes are configured identically.

**3. Control plane.** `kubeadm init` with an explicit pod CIDR matching the chosen CNI, the
private IP as the advertise address, and the public IP added to the API server certificate so
the cluster is reachable with kubectl from outside the VPC.

**4. Pod networking.** Flannel applied as a DaemonSet. It allocates a `/24` per node out of
the pod CIDR and builds a VXLAN overlay between them.

**5. Worker join.** The worker authenticates with a bootstrap token and verifies the control
plane against a CA certificate hash before joining.

---

## Engineering decisions

**containerd on the systemd cgroup driver.** Ubuntu manages cgroups with systemd and so does
kubelet. Leaving containerd on the cgroupfs driver puts two components in contention over the
same cgroups, and kubelet then fails with an error that never mentions cgroups. This is the
most common cause of a kubeadm bootstrap that dies for no visible reason.

**Replacing Ubuntu's containerd config outright.** The packaged config ships with the CRI
plugin disabled. Kubernetes talks to the runtime exclusively over CRI, so the stub has to be
replaced with the generated default rather than edited.

**Public IP in the API server certificate.** Without an extra SAN the certificate covers only
the private IP, and any kubectl call from outside the VPC fails on a name mismatch. Easier to
get right at init than to fix afterwards.

**Pod CIDR chosen to match the CNI.** Flannel expects `10.244.0.0/16`. A mismatch between
this and the value given to kubeadm leaves pods scheduled but without addresses, and the
failure gives no useful signal.

**One security group with self-referencing ingress.** Rather than enumerating the API server,
etcd, kubelet, scheduler, controller-manager and VXLAN ports individually, cluster members are
permitted to reach each other on all ports by group membership. External access stays
restricted to one address.

**Control plane left schedulable.** The `NoSchedule` taint is removed so both nodes carry
workloads and cross-node networking can be exercised. Production keeps the taint.

---

## Verification

Confirmed working by using a throwaway pod pinned to one node fetching from a pod IP on the
other node, so the request has to traverse the overlay. Nodes reporting `Ready` does not
establish that the pod network works.

---

## Known limitations

- Terraform state is local
- Single control plane, so no API server high availability
- Node preparation is a shell script, not idempotent configuration management
- No etcd backup

---

## Roadmap

- Remote Terraform state, S3 backend with state locking
- Ansible replacing the node preparation script
- Highly available control plane: three nodes behind a load balancer, stacked etcd
- etcd snapshot and restore
- Argo CD syncing an application chart from a separate repository
- Control plane version upgrade
- Cluster-level failure catalogue
