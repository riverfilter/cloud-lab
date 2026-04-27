# cloud-lab CIDR allocation

One lab per cloud assumed. If a second lab is needed in the same
cloud, allocate from the "reserved for second lab" column. Cross-cloud
collision is not possible today because each cloud occupies a distinct
/16 (or higher) block.

## Default allocation

| Stack | Primary CIDR | Sub-ranges | Reserved (2nd lab) |
|-------|--------------|------------|---------------------|
| `gcp-management-tf` | (subnet only) | subnet `10.10.0.0/24` | `10.11.0.0/16` |
| `gcp-gke-tf`        | (subnet-mode) | nodes `10.20.0.0/24`, pods `10.21.0.0/16`, services `10.22.0.0/20`, master peering `172.16.0.0/28` | `10.23.0.0/16`–`10.29.0.0/16` |
| `aws-eks-tf`        | VPC `10.30.0.0/16` | `/20` per AZ × 2 public + 2 private (`10.30.0.0/20`, `10.30.16.0/20`, `10.30.32.0/20`, `10.30.48.0/20`) | `10.31.0.0/16`–`10.39.0.0/16` |
| `azure-aks-tf`      | VNet `10.40.0.0/16` | nodes subnet `10.40.0.0/20`, pods `10.244.0.0/16`, services `10.41.0.0/16` | `10.42.0.0/16`–`10.49.0.0/16` |

Sources of truth (defaults; tfvars may override):

- `gcp-management-tf/variables.tf` — `subnet_cidr`
- `gcp-gke-tf/variables.tf` — `subnet_cidr`, `pods_cidr`, `services_cidr`, `master_ipv4_cidr_block`
- `aws-eks-tf/variables.tf` — `vpc_cidr`; subnets carved in `aws-eks-tf/network.tf` via `cidrsubnet(var.vpc_cidr, 4, i)` (= `/20` per subnet, 4 subnets total at the default 2-AZ count)
- `azure-aks-tf/variables.tf` — `vnet_cidr`, `nodes_subnet_cidr`, `pod_cidr`, `service_cidr`

## Notes

- **AKS `pod_cidr` (`10.244.0.0/16`)** is the Kubernetes/Flannel
  convention for the pod range; preserved here even though Azure CNI
  Overlay routes pods natively (the range is not part of the VNet).
- **AKS `service_cidr` (`10.41.0.0/16`)** is adjacent to — not
  overlapping — the VNet `10.40.0.0/16`. Azure requires the service
  range not overlap the VNet or the pod range; both constraints hold.
  Note that `10.41.0.0/16` consumes the first slot of the AKS reserved
  range, which is why the second-lab reservation starts at `10.42.0.0/16`.
- **GKE `master_ipv4` (`172.16.0.0/28`)** sits outside the user VPC
  because the GKE control-plane peering VPC is Google-owned. `/28` is
  the smallest GKE accepts.
- **EKS pods share VPC primary IPs** via the AWS VPC CNI — no
  separate pod range. Each pod consumes one ENI secondary IP from the
  AZ subnet.
- **EKS subnet sizing.** With the default `availability_zone_count = 2`
  the VPC `/16` is split into four `/20`s (2 public + 2 private).
  Bumping to 3 AZs yields six `/20`s (3 public + 3 private), still
  inside the same `/16` and unchanged in the table above.
- **Mgmt VM ↔ cluster control plane** path is currently *over the
  public internet* via the mgmt VM's static NAT egress IP
  (`gcp-management-tf` `nat_public_ip`) appended to each cluster's
  `authorized_cidrs`. The allocation above is non-overlapping by
  design so a future fully-private peering arc is unblocked.
- **Second-lab allocation** is preemptive — not implemented today. If
  you need a second cluster in the same cloud, pick from the reserved
  range and update each stack's tfvars accordingly.

## Future considerations

- VPC peering (mgmt-tf VPC ↔ cluster VPCs) requires the master
  peering VPC be reachable from mgmt — for GKE, that means setting
  `master_authorized_networks` to the mgmt VPC's primary range AND
  configuring the master-peering VPC's authorized list. Out of scope
  today.
- IPv6: not allocated. AKS, EKS, and GKE all support dual-stack to
  varying degrees; not a current goal.
