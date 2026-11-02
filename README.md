# Kubernetes cluster on AWS with kubeadm

A two-node Kubernetes cluster built on AWS without a managed control plane.
Terraform provisions the infrastructure, Ansible prepares the nodes and bootstraps the
cluster, Argo CD delivers the application from a separate repository.

**Stack:** Kubernetes (kubeadm), Terraform, Ansible, Argo CD, AWS EC2, containerd, Flannel

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
│   │  argocd          │      │                  │       │
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

## Two repositories, one platform

Infrastructure and application are deliberately separate. This repository owns the
cluster. The application repository owns what runs on it. Argo CD is the only thing
that spans both.

```
  kubeadm-cluster-aws                      k8s-project
  (this repository)                        (application repository)
          │                                        │
          │ Terraform, Ansible                     │ Helm chart
          ▼                                        │
   EC2 + Kubernetes ──────── Argo CD ◄─────────────┘
                             watches, renders, applies
```

Argo CD runs with auto-sync and self-heal, so the cluster is reconciled against Git
rather than against whatever was last typed into kubectl.

---

## Repository layout

```
.
├── terraform/                      # AWS layer
│   ├── main.tf                     # VPC, subnet, security group, key pair, instances
│   ├── variables.tf
│   └── outputs.tf
└── ansible/                        # node preparation and cluster bootstrap
    ├── ansible.cfg
    ├── inventory.aws_ec2.yml       # live EC2 inventory, grouped by instance tag
    ├── group_vars/all.yml          # Kubernetes version, pod CIDR
    ├── site.yml
    └── roles/
        ├── common/                 # swap, kernel modules, sysctl, containerd, packages
        ├── control_plane/          # kubeadm init, kubeconfig, CNI
        ├── worker/                 # kubeadm join
        └── argocd/                 # Argo CD and the Application
```

---

## How it was built

**1. AWS layer, Terraform.** A VPC with a public subnet, internet gateway and route
table, plus a security group that exposes SSH, the Kubernetes API and the NodePort range
to a single source IP while allowing unrestricted traffic between cluster members. Two
t3.medium instances with 20 GB gp3 root volumes, tagged by role.

**2. Node preparation, Ansible.** Both nodes are brought to a state kubeadm will accept:
hostname set from the instance tag, swap disabled permanently, the `overlay` and
`br_netfilter` kernel modules loaded, IP forwarding and bridge netfilter enabled via
sysctl, containerd installed and moved onto the systemd cgroup driver, and the Kubernetes
apt repository added with the packages version-locked.

**3. Control plane.** `kubeadm init` with an explicit pod CIDR matching the chosen CNI,
the private IP as the advertise address, and the public IP added to the API server
certificate so the cluster is reachable with kubectl from outside the VPC.

**4. Pod networking.** Flannel applied as a DaemonSet. It allocates a `/24` per node out
of the pod CIDR and builds a VXLAN overlay between them.

**5. Worker join.** A bootstrap token is minted on the control plane at run time and the
worker verifies the control plane against a CA certificate hash before joining. No token
is ever stored in the repository.

**6. Argo CD.** Installed into its own namespace, exposed on a NodePort, and handed an
Application pointing at the Helm chart in the application repository. From that point the
cluster reconciles itself against Git.

---

## Engineering decisions

**containerd on the systemd cgroup driver.** Ubuntu manages cgroups with systemd and so
does kubelet. containerd defaults to cgroupfs, which puts two components in contention
over the same cgroups, and kubelet then fails with an error that never mentions cgroups.
This is the most common cause of a kubeadm bootstrap that dies for no visible reason.
Ubuntu's containerd package ships no config file at all, so one is generated in order to
have somewhere to set the driver.

**Public IP in the API server certificate.** Without an extra SAN the certificate covers
only the private IP, and any kubectl call from outside the VPC fails on a name mismatch.
Easier to get right at init than to fix afterwards.

**Pod CIDR chosen to match the CNI.** Flannel expects `10.244.0.0/16`. A mismatch between
this and the value given to kubeadm leaves pods scheduled but without addresses, and the
failure gives no useful signal.

**One security group with self-referencing ingress.** Rather than enumerating the API
server, etcd, kubelet, scheduler, controller-manager and VXLAN ports individually, cluster
members are permitted to reach each other on all ports by group membership. External
access stays restricted to one address.

**The source IP is looked up, not configured.** A home connection gets a new public
address regularly, and every change silently breaks SSH and the API server. A `http` data
source resolves it at plan time, so `terraform apply` alone repairs the firewall. The
trade-off is a network call during plan, which a production configuration would avoid
because the plan then depends on an external service. Acceptable for infrastructure whose
purpose is to be rebuilt often.

**EC2 dynamic inventory rather than a host list.** Public IPs change on every rebuild.
The inventory queries the EC2 API and groups hosts by their `Role` tag, so no address is
written down and a rebuild needs no inventory edit. It also means the Terraform tags and
the Ansible group names are a contract between the two layers.

**Idempotency treated as a requirement, not a nice-to-have.** The containerd config is
only generated when absent or incomplete, rather than regenerated every run, because
regenerating resets the cgroup driver and would restart the container runtime under a
live cluster on every playbook run. A second run of the playbook against a built cluster
reports zero changes.

**Server-side apply for Argo CD.** The ApplicationSet CRD exceeds the 262144-byte limit
on the annotation that client-side apply uses to record the last applied configuration.
A plain `kubectl apply` fails on that one object with an error about annotation size that
says nothing about apply strategy.

**Control plane left schedulable.** The `NoSchedule` taint is removed so both nodes carry
workloads and cross-node networking can be exercised. Production keeps the taint.

---

## Verification

Nodes reporting `Ready` does not establish that the pod network works. Confirmed working
by using a throwaway pod pinned to one node fetching from a pod IP on the other node, so
the request has to traverse the overlay.

The rebuild path is verified the same way, by doing it. `terraform destroy`,
`terraform apply`, `ansible-playbook site.yml` returns a two-node cluster with Flannel,
Argo CD and the application synced, with no manual step and no address edited anywhere.
Run twice, both times reporting no failed tasks. A third run against the standing cluster
reports zero changes.

---

## Known limitations

- Terraform state is local
- Single control plane, so no API server high availability
- No etcd backup
- Argo CD is exposed on a NodePort with a self-signed certificate

---

## Roadmap

- Remote Terraform state, S3 backend with state locking
- Highly available control plane: three nodes behind a load balancer, stacked etcd
- etcd snapshot and restore
- Control plane version upgrade
- Cluster-level failure catalogue
