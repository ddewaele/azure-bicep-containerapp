# VNet Peering Demo — Hub-Spoke Topology

Deploys a hub-spoke network with three VNets, two subnets each, peered through a central hub. Includes VMs in different subnets and VNets to test connectivity scenarios.

## Architecture

```
                    ┌─────────────────────────────────┐
                    │     Hub VNet — 10.0.0.0/16       │
                    │                                  │
                    │  ┌───────────────────────────┐   │
                    │  │ shared      10.0.1.0/24   │   │
                    │  │ hub-vm (public IP for SSH) │   │
                    │  └───────────────────────────┘   │
                    │  ┌───────────────────────────┐   │
                    │  │ management  10.0.2.0/24   │   │
                    │  └───────────────────────────┘   │
                    └──────────┬───────┬───────────────┘
                       peering │       │ peering
              ┌────────────────┘       └────────────────┐
              ▼                                         ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│  Spoke A VNet — 10.1.0.0/16  │   │  Spoke B VNet — 10.2.0.0/16  │
│                               │   │                               │
│  ┌────────────────────────┐   │   │  ┌────────────────────────┐   │
│  │ web       10.1.1.0/24 │   │   │  │ web       10.2.1.0/24 │   │
│  │ spoke-a-web            │   │   │  │ spoke-b-web            │   │
│  └────────────────────────┘   │   │  └────────────────────────┘   │
│  ┌────────────────────────┐   │   │  ┌────────────────────────┐   │
│  │ app       10.1.2.0/24 │   │   │  │ data      10.2.2.0/24 │   │
│  │ spoke-a-app            │   │   │  │ spoke-b-data           │   │
│  └────────────────────────┘   │   │  └────────────────────────┘   │
└──────────────────────────────┘   └──────────────────────────────┘
           ✗ no direct peering ✗
```

## What gets deployed

| Resource | Purpose |
|---|---|
| Hub VNet (10.0.0.0/16) | Central hub — shared services, jump box |
| Spoke A VNet (10.1.0.0/16) | First workload — web + app tiers |
| Spoke B VNet (10.2.0.0/16) | Second workload — web + data tiers |
| Hub ↔ Spoke A peering | Bidirectional peering |
| Hub ↔ Spoke B peering | Bidirectional peering |
| NSG | Allows SSH + ICMP (ping) between all VNets |
| hub-vm (B1s) | Jump box in Hub/shared subnet — only VM with a public IP |
| spoke-a-web (B1s) | Web tier VM in Spoke A |
| spoke-a-app (B1s) | App tier VM in Spoke A (different subnet) |
| spoke-b-web (B1s) | Web tier VM in Spoke B |
| spoke-b-data (B1s) | Data tier VM in Spoke B (different subnet) |
| 1x Public IP (Standard) | SSH access to hub-vm only |

## Address space plan

| VNet | CIDR | Subnet | Subnet CIDR |
|---|---|---|---|
| Hub | 10.0.0.0/16 | shared | 10.0.1.0/24 |
| | | management | 10.0.2.0/24 |
| Spoke A | 10.1.0.0/16 | web | 10.1.1.0/24 |
| | | app | 10.1.2.0/24 |
| Spoke B | 10.2.0.0/16 | web | 10.2.1.0/24 |
| | | data | 10.2.2.0/24 |

No overlaps — all three VNets are peerable.

## VMs

| VM | VNet | Subnet | Private IP range | Public IP | Role |
|---|---|---|---|---|---|
| hub-vm | Hub | shared | 10.0.1.x | Yes | Jump box + IP forwarding (router) |
| spoke-a-web | Spoke A | web | 10.1.1.x | No | Web tier |
| spoke-a-app | Spoke A | app | 10.1.2.x | No | App tier |
| spoke-b-web | Spoke B | web | 10.2.1.x | No | Web tier |
| spoke-b-data | Spoke B | data | 10.2.2.x | No | Data tier |

Only hub-vm has a public IP. All other VMs are accessed by SSH-ing through hub-vm (jump box pattern).

## Estimated cost

5x B2ats_v2 VMs + 1 Standard IP + 5 disks = **~$40/month**. VNet peering is free within the same region.

## Project structure

```
vnet-peering/
├── 01-vnets.bicep             # Step 1: 3 VNets, 6 subnets, 5 VMs (no peering)
├── 02-peering.bicep           # Step 2: Hub↔Spoke peering
├── 03-hub-routing.bicep       # Step 3: IP forwarding + UDRs for spoke-to-spoke
├── parameters/
│   └── main.bicepparam        # Shared parameters for step 1
└── README.md
```

Each file is deployed incrementally to the same resource group. Later steps reference resources created by earlier steps using the Bicep `existing` keyword.

## Deploy

### Step 1 — VNets, subnets, VMs (no peering)

```bash
az group create --name rg-vnet-peering --location westeurope

az deployment group create \
  --resource-group rg-vnet-peering \
  --template-file 01-vnets.bicep \
  --parameters parameters/main.bicepparam \
  --parameters sshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
```

After this step, test **Scenario 1** (same VNet, different subnets — works) and **Scenario 4** (cross-VNet — fails).

### Step 2 — Add hub-spoke peering

```bash
az deployment group create \
  --resource-group rg-vnet-peering \
  --template-file 02-peering.bicep
```

No parameters needed — it references the existing VNets by name. Test **Scenarios 2 and 3** (hub↔spoke — works) and **Scenario 4 again** (spoke-to-spoke — still fails).

### Step 3 — Enable spoke-to-spoke routing via hub

```bash
az deployment group create \
  --resource-group rg-vnet-peering \
  --template-file 03-hub-routing.bicep
```

Then SSH into hub-vm and enable IP forwarding in the OS:

```bash
sudo sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
```

Test **Scenario 5** (spoke-to-spoke via hub — works).

## Connect

SSH into hub-vm (the only VM with a public IP), then jump to the others:

```bash
# Get hub-vm's public IP
az deployment group show \
  --resource-group rg-vnet-peering \
  --name main \
  --query "properties.outputs" \
  --output table

# SSH into hub-vm
ssh azureuser@<hub-vm-public-ip>

# From hub-vm, SSH to any spoke VM via its private IP
ssh azureuser@10.1.1.4    # spoke-a-web
ssh azureuser@10.1.2.4    # spoke-a-app
ssh azureuser@10.2.1.4    # spoke-b-web
ssh azureuser@10.2.2.4    # spoke-b-data
```

For this to work, copy your SSH private key to hub-vm or use SSH agent forwarding:

```bash
# Option: SSH agent forwarding (key stays on your machine)
ssh -A azureuser@<hub-vm-public-ip>
```

---

## Connectivity scenarios to test

### Scenario 1 — Same VNet, different subnets

**Test:** From spoke-a-web (10.1.1.x), ping spoke-a-app (10.1.2.x)

```bash
# On spoke-a-web:
ping 10.1.2.4
```

**Expected:** Works. Subnets within the same VNet can communicate by default — no peering needed, no extra configuration.

**Lesson:** A VNet is a flat network at layer 3. Subnets are just organizational boundaries. All subnets in a VNet can route to each other unless you add NSG rules to block it.

### Scenario 2 — Hub to spoke

**Test:** From hub-vm (10.0.1.x), ping spoke-a-web (10.1.1.x)

```bash
# On hub-vm:
ping 10.1.1.4
```

**Expected:** Works. Hub is peered with Spoke A, so traffic flows across the peering.

**Lesson:** VNet peering creates routes between the two VNets. Any VM in Hub can reach any VM in Spoke A (and vice versa) as long as NSGs allow it.

### Scenario 3 — Spoke to hub

**Test:** From spoke-b-web (10.2.1.x), ping hub-vm (10.0.1.x)

```bash
# On spoke-b-web:
ping 10.0.1.4
```

**Expected:** Works. Peering is bidirectional — Spoke B can reach Hub just as Hub can reach Spoke B.

### Scenario 4 — Spoke to spoke (fails!)

**Test:** From spoke-a-web (10.1.1.x), ping spoke-b-web (10.2.1.x)

```bash
# On spoke-a-web:
ping 10.2.1.4
```

**Expected:** Fails (timeout). There is no peering between Spoke A and Spoke B.

**Lesson:** **Peering is NOT transitive.** Even though Spoke A ↔ Hub ↔ Spoke B, traffic from Spoke A does not automatically flow through Hub to reach Spoke B. Each peering is a direct point-to-point link. This is the single most important concept in Azure networking.

### Scenario 5 — Spoke to spoke via hub (IP forwarding + UDRs)

To make spoke-to-spoke traffic flow through the hub, you need three things:

1. **Enable IP forwarding** on hub-vm's NIC (so it acts as a router)
2. **Enable IP forwarding** inside hub-vm's OS
3. **Create User Defined Routes (UDRs)** on the spoke subnets pointing to hub-vm

```bash
# 1. Enable IP forwarding on hub-vm's NIC (from your local machine)
az network nic update \
  --resource-group rg-vnet-peering \
  --name hub-vm-nic \
  --ip-forwarding true

# 2. Enable IP forwarding in the OS (on hub-vm)
sudo sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf

# 3. Create a route table pointing spoke traffic through hub-vm
HUB_VM_IP=10.0.1.4

# Route table for Spoke A: "to reach Spoke B, go through hub-vm"
az network route-table create \
  --resource-group rg-vnet-peering \
  --name spoke-a-to-b-rt \
  --location westeurope

az network route-table route create \
  --resource-group rg-vnet-peering \
  --route-table-name spoke-a-to-b-rt \
  --name to-spoke-b \
  --address-prefix 10.2.0.0/16 \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address $HUB_VM_IP

# Attach route table to Spoke A subnets
az network vnet subnet update \
  --resource-group rg-vnet-peering \
  --vnet-name spoke-a-vnet \
  --name web \
  --route-table spoke-a-to-b-rt

az network vnet subnet update \
  --resource-group rg-vnet-peering \
  --vnet-name spoke-a-vnet \
  --name app \
  --route-table spoke-a-to-b-rt

# Route table for Spoke B: "to reach Spoke A, go through hub-vm"
az network route-table create \
  --resource-group rg-vnet-peering \
  --name spoke-b-to-a-rt \
  --location westeurope

az network route-table route create \
  --resource-group rg-vnet-peering \
  --route-table-name spoke-b-to-a-rt \
  --name to-spoke-a \
  --address-prefix 10.1.0.0/16 \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address $HUB_VM_IP

az network vnet subnet update \
  --resource-group rg-vnet-peering \
  --vnet-name spoke-b-vnet \
  --name web \
  --route-table spoke-b-to-a-rt

az network vnet subnet update \
  --resource-group rg-vnet-peering \
  --vnet-name spoke-b-vnet \
  --name data \
  --route-table spoke-b-to-a-rt
```

Also enable "Allow Forwarded Traffic" on the peerings:

```bash
az network vnet peering update \
  --resource-group rg-vnet-peering \
  --vnet-name spoke-a-vnet \
  --name spoke-a-to-hub \
  --set allowForwardedTraffic=true

az network vnet peering update \
  --resource-group rg-vnet-peering \
  --vnet-name spoke-b-vnet \
  --name spoke-b-to-hub \
  --set allowForwardedTraffic=true
```

Now retry the ping from spoke-a-web to spoke-b-web:

```bash
# On spoke-a-web:
ping 10.2.1.4
```

**Expected:** Works. The traffic flows: spoke-a-web → hub-vm (forwarded) → spoke-b-web.

**Lesson:** In a real hub-spoke network, the hub VM would be replaced by an **Azure Firewall** or **Network Virtual Appliance (NVA)** that inspects, filters, and routes all inter-spoke traffic.

### Scenario 6 — NSG blocking traffic between subnets

By default, all subnets in a VNet can communicate. You can add NSG rules to restrict this.

**Test:** Block ICMP from web subnet to app subnet within Spoke A:

```bash
az network nsg rule create \
  --resource-group rg-vnet-peering \
  --nsg-name spoke-a-app-nsg \
  --name DenyPingFromWeb \
  --priority 100 \
  --direction Inbound \
  --access Deny \
  --protocol Icmp \
  --source-address-prefix 10.1.1.0/24 \
  --destination-address-prefix 10.1.2.0/24

# On spoke-a-web:
ping 10.1.2.4    # now fails
```

**Lesson:** NSGs are the subnet-level firewall. Even within the same VNet, you should use NSGs to enforce least-privilege access between tiers (e.g. only the web tier can talk to the app tier on port 8080).

---

## Key takeaways

| Concept | What we learned |
|---|---|
| **Subnets are open by default** | VMs in different subnets of the same VNet communicate freely unless NSGs block it |
| **Peering is NOT transitive** | Spoke A ↔ Hub ↔ Spoke B does NOT mean Spoke A ↔ Spoke B |
| **Hub-spoke is the standard pattern** | Shared services (firewall, DNS, VPN) live in the hub; spokes are isolated workloads |
| **IP forwarding + UDRs enable spoke-to-spoke** | The hub VM acts as a router; in production, use Azure Firewall instead |
| **NSGs control traffic at the subnet level** | Use them to enforce segmentation even within a VNet |
| **Only the hub needs a public IP** | Spoke VMs are accessed via the hub (jump box / bastion pattern) |

## Verify peering status

```bash
# Hub peerings
az network vnet peering list \
  --resource-group rg-vnet-peering \
  --vnet-name hub-vnet \
  --output table

# Spoke A peerings
az network vnet peering list \
  --resource-group rg-vnet-peering \
  --vnet-name spoke-a-vnet \
  --output table
```

All peerings should show `PeeringState: Connected`.

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

### What if you can't re-address?

If production workloads are already running on overlapping ranges and re-addressing is not feasible:

1. **Use a NAT gateway or Azure Firewall** between the VNets — translate the overlapping addresses to a unique range at the network boundary
2. **Use Private Link / Private Endpoints** — expose specific services across VNets without full network-level peering
3. **Use a VPN Gateway with NAT rules** — Azure VPN Gateway supports NAT rules that remap address ranges during transit

All of these are workarounds. The clean solution is always to plan non-overlapping address spaces from the start.

### Address space planning guidelines

| Network | CIDR | Range | Use |
|---|---|---|---|
| Hub | 10.0.0.0/16 | 10.0.0.0 – 10.0.255.255 | Shared services |
| Spoke A | 10.1.0.0/16 | 10.1.0.0 – 10.1.255.255 | First workload |
| Spoke B | 10.2.0.0/16 | 10.2.0.0 – 10.2.255.255 | Second workload |
| Spoke C | 10.3.0.0/16 | 10.3.0.0 – 10.3.255.255 | Third workload |
| On-premises | 172.16.0.0/12 | 172.16.0.0 – 172.31.255.255 | Corporate network |

Using a `/16` per VNet gives 65,536 addresses each — far more than enough for most workloads — while keeping all VNets peerable with each other and with on-premises via VPN/ExpressRoute.
