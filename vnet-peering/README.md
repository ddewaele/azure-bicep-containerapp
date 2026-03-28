# VNet Peering Demo

Deploys two virtual networks with a VM in each, peered together so the VMs can communicate via private IP addresses.

## Architecture

```
┌──────────────────────────┐         ┌──────────────────────────┐
│  VNet A — 10.1.0.0/16    │         │  VNet B — 10.2.0.0/16    │
│                          │         │                          │
│  ┌────────────────────┐  │ peering │  ┌────────────────────┐  │
│  │ vm-a               │  │◄───────►│  │ vm-b               │  │
│  │ 10.1.0.x (private) │  │         │  │ 10.2.0.x (private) │  │
│  │ + public IP (SSH)  │  │         │  │ + public IP (SSH)  │  │
│  └────────────────────┘  │         │  └────────────────────┘  │
└──────────────────────────┘         └──────────────────────────┘
```

## What gets deployed

| Resource | Purpose |
|---|---|
| VNet A (10.1.0.0/16) | First virtual network |
| VNet B (10.2.0.0/16) | Second virtual network |
| Peering A↔B | Bidirectional VNet peering |
| NSG | Allows SSH + ICMP (ping) |
| vm-a (B1s) | Test VM in VNet A |
| vm-b (B1s) | Test VM in VNet B |
| 2x Public IP (Standard) | SSH access to each VM |

## Estimated cost

Two B1s VMs + 2 Standard IPs + 2 disks = **~$17/month**. VNet peering itself is free within the same region.

## Deploy

```bash
az group create --name rg-vnet-peering --location westeurope

az deployment group create \
  --resource-group rg-vnet-peering \
  --template-file main.bicep \
  --parameters parameters/main.bicepparam \
  --parameters sshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
```

## Test peering

```bash
# Get connection info
az deployment group show \
  --resource-group rg-vnet-peering \
  --name main \
  --query "properties.outputs" \
  --output table

# SSH into vm-a
ssh azureuser@<vm-a-public-ip>

# From vm-a, ping vm-b via its private IP (crosses the peering)
ping 10.2.0.4
```

If peering is working, you'll see ping replies. The traffic goes through Azure's backbone network — it never touches the internet.

## Verify peering status

```bash
az network vnet peering list \
  --resource-group rg-vnet-peering \
  --vnet-name vnet-a \
  --output table
```

Both peerings should show `PeeringState: Connected`.

## Tear down

```bash
az group delete --name rg-vnet-peering --yes
```

---

## Why overlapping address spaces break peering

Azure VNet peering requires **non-overlapping CIDR ranges**. If two VNets have addresses that overlap, Azure rejects the peering creation.

### Example: what doesn't work

```
VNet A:  10.0.0.0/16   (covers 10.0.0.0 – 10.0.255.255)
VNet B:  10.0.0.0/24   (covers 10.0.0.0 – 10.0.0.255)
```

VNet B's range is entirely inside VNet A's range. Azure cannot create a route table that unambiguously says "send 10.0.0.5 to VNet A" vs "send 10.0.0.5 to VNet B" — the address exists in both.

The Azure Portal shows this error:

> *This address prefix overlaps with virtual network 'cheapvm-vnet'. If you intend to peer these virtual networks, change the address space.*

### How to fix it

You must **re-address** one or both VNets so they don't overlap:

| VNet | Before (broken) | After (working) |
|---|---|---|
| VNet A | 10.0.0.0/16 | **10.1.0.0/16** |
| VNet B | 10.0.0.0/24 | **10.2.0.0/16** |

This is what the Bicep template in this project does — VNet A uses `10.1.0.0/16` and VNet B uses `10.2.0.0/16`.

### What if you can't re-address?

If production workloads are already running on overlapping ranges and re-addressing is not feasible:

1. **Use a NAT gateway or Azure Firewall** between the VNets — translate the overlapping addresses to a unique range at the network boundary
2. **Use Private Link / Private Endpoints** — expose specific services across VNets without full network-level peering
3. **Use a VPN Gateway with NAT rules** — Azure VPN Gateway supports NAT rules that remap address ranges during transit

All of these are workarounds. The clean solution is always to plan non-overlapping address spaces from the start.

### Address space planning guidelines

| Network | CIDR | Range | Use |
|---|---|---|---|
| VNet A | 10.1.0.0/16 | 10.1.0.0 – 10.1.255.255 | First workload |
| VNet B | 10.2.0.0/16 | 10.2.0.0 – 10.2.255.255 | Second workload |
| VNet C | 10.3.0.0/16 | 10.3.0.0 – 10.3.255.255 | Third workload |
| On-premises | 172.16.0.0/12 | 172.16.0.0 – 172.31.255.255 | Corporate network |

Using a `/16` per VNet gives 65,536 addresses each — far more than enough for most workloads — while keeping all VNets peerable with each other and with on-premises via VPN/ExpressRoute.
