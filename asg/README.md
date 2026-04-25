# Application Security Groups (ASG)

Demonstrates how **Application Security Groups** let you write NSG rules using logical tier names (`asg-web`, `asg-logic`, `asg-db`) instead of IP addresses. Adding a new VM to a tier only requires assigning its NIC to the right ASG — no rule changes needed.

## Architecture

```
VIRTUAL NETWORK  10.0.0.0/16
│
├── AzureBastionSubnet  10.0.3.0/26
│     └── asg-bastion  (Standard SKU, public IP, native client tunneling)
│
├── web-subnet  10.0.1.0/24  ── nsg-web (subnet level)
│     ├── web-vm-1  NIC → asg-web    (Node.js :80, public IP)
│     ├── web-vm-2  NIC → asg-web    (Node.js :80)
│     └── logic-vm  NIC → asg-logic  (Node.js :3000)
│              └── NIC NSG: nsg-nic-logic-vm (deny outbound Internet)
│
└── db-subnet   10.0.2.0/24  ── nsg-db (subnet level)
      └── db-vm   NIC → asg-db     (PostgreSQL :5432)
```

## NSG rules

NSGs can be applied at **subnet level** (affects all NICs in the subnet) or at
**NIC level** (affects only one NIC). Azure evaluates them in order:

- **Inbound**: subnet NSG → NIC NSG → VM (both must allow)
- **Outbound**: NIC NSG → subnet NSG → wire (both must allow)

NIC NSGs can add restrictions beyond the subnet NSG but cannot override a
subnet DENY.

### nsg-web (subnet level on web-subnet)

| Priority | Name | Source | Destination | Port | Action |
|---|---|---|---|---|---|
| 100 | allow-internet-to-web | Internet | `asg-web` | 80 | Allow ✅ |
| 110 | allow-web-to-logic | `asg-web` | `asg-logic` | 3000 | Allow ✅ |
| 200 | allow-bastion-ssh-web | VirtualNetwork | `asg-web` | 22 | Allow ✅ |
| 210 | allow-bastion-ssh-logic | VirtualNetwork | `asg-logic` | 22 | Allow ✅ |
| 300 | deny-internet-to-logic | Internet | `asg-logic` | * | Deny ❌ |
| 4000 | deny-all-inbound | * | * | * | Deny ❌ |

### nsg-db (subnet level on db-subnet)

| Priority | Name | Source | Destination | Port | Action |
|---|---|---|---|---|---|
| 100 | allow-logic-to-db | `asg-logic` | `asg-db` | 5432 | Allow ✅ |
| 200 | allow-bastion-ssh-db | VirtualNetwork | `asg-db` | 22 | Allow ✅ |
| 300 | deny-web-to-db | `asg-web` | `asg-db` | * | Deny ❌ |
| 4000 | deny-all-inbound | * | * | * | Deny ❌ |

### nsg-nic-logic-vm (NIC level on logic-vm)

Attached directly to logic-vm's NIC. Demonstrates per-VM hardening on top
of the shared subnet NSG.

| Priority | Name | Direction | Source | Destination | Port | Action |
|---|---|---|---|---|---|---|
| 100 | deny-outbound-internet | Outbound | * | Internet | * | Deny ❌ |

## Deploy

> **Cost note:** Standard SKU Bastion costs ~$0.38/hr (~$280/month). Delete the resource group when done.

```bash
LOCATION=westeurope
RG=rg-asg-demo

az group create --name $RG --location $LOCATION

# Step 1 — network topology, ASGs, NSGs
az deployment group create \
  --resource-group $RG \
  --template-file 01-network.bicep \
  --parameters @parameters/01-network.json

# Step 2 — VMs
az deployment group create \
  --resource-group $RG \
  --template-file 02-vms.bicep \
  --parameters @parameters/02-vms.json \
  --parameters sshPublicKey="$(cat ~/.ssh/azure-cheap-vm/ed25519.pub)"
```

## Get private IPs

```bash
az deployment group show \
  --resource-group $RG \
  --name 02-vms \
  --query properties.outputs
```

## Test the rules

Cloud-init takes ~2 minutes after deployment to finish installing packages.

We'll test SSH access first so you get familiar with the Bastion commands, then
use those sessions to verify the HTTP/database rules from inside the VMs.

---

## 1. SSH access tests

> **Note:** Standard SKU Bastion supports both browser-based SSH (Portal → VM → Connect → Bastion) and native client (`az network bastion ssh`) via `enableTunneling`. Commands below show both options.

### ❌ Internet → web-vm-1 SSH (should be blocked)

> **Why it's blocked:** `nsg-web` has no rule that allows SSH (port 22) from the `Internet` service tag to `asg-web`. The only SSH allow rule uses `VirtualNetwork` as the source — Bastion lives inside the VNet and matches that tag, but your laptop does not. The `deny-all-inbound` rule at priority 4000 catches the connection and drops it.

`web-vm-1` has a public IP, but that doesn't mean all ports are open:

```bash
WEB_IP=$(az deployment group show -g $RG -n 02-vms \
  --query properties.outputs.webVm1PublicIp.value -o tsv)

ssh azureuser@$WEB_IP
# ssh: connect to host <ip> port 22: Connection timed out — no matching allow rule ✅
```

### ✅ Bastion → web-vm-1 SSH (should work)

> **Why it works:** Azure Bastion sits in `AzureBastionSubnet` inside the same VNet. Traffic from Bastion to a VM is tagged as `VirtualNetwork`, which matches `allow-bastion-ssh-web` (priority 200): `VirtualNetwork` → `asg-web` port 22.

**Option A — Browser (Portal):** Portal → web-vm-1 → Connect → Bastion

**Option B — Native client:**
```bash
WEB_VM_ID=$(az vm show -g $RG -n web-vm-1 --query id -o tsv)

az network bastion ssh \
  --name asg-bastion \
  --resource-group $RG \
  --target-resource-id $WEB_VM_ID \
  --auth-type ssh-key \
  --username azureuser \
  --ssh-key ~/.ssh/azure-cheap-vm/ed25519
```

Once connected:
```bash
hostname   # web-vm-1
```

### ✅ Bastion → logic-vm SSH (should work)

> **Why it works:** Same mechanism — Bastion traffic carries the `VirtualNetwork` tag, which matches `allow-bastion-ssh-logic` (priority 210): `VirtualNetwork` → `asg-logic` port 22.

**Option A — Browser (Portal):** Portal → logic-vm → Connect → Bastion

**Option B — Native client:**
```bash
LOGIC_VM_ID=$(az vm show -g $RG -n logic-vm --query id -o tsv)

az network bastion ssh \
  --name asg-bastion \
  --resource-group $RG \
  --target-resource-id $LOGIC_VM_ID \
  --auth-type ssh-key \
  --username azureuser \
  --ssh-key ~/.ssh/azure-cheap-vm/ed25519
```

Once connected:
```bash
hostname   # logic-vm
```

### ✅ Bastion → db-vm SSH (should work)

> **Why it works:** `nsg-db` has `allow-bastion-ssh-db` (priority 200): `VirtualNetwork` → `asg-db` port 22. Bastion traffic matches the `VirtualNetwork` tag, so it's allowed through even though the db subnet has its own NSG.

**Option A — Browser (Portal):** Portal → db-vm → Connect → Bastion

**Option B — Native client:**
```bash
DB_VM_ID=$(az vm show -g $RG -n db-vm --query id -o tsv)

az network bastion ssh \
  --name asg-bastion \
  --resource-group $RG \
  --target-resource-id $DB_VM_ID \
  --auth-type ssh-key \
  --username azureuser \
  --ssh-key ~/.ssh/azure-cheap-vm/ed25519
```

Once connected:
```bash
hostname   # db-vm
```

### ✅ web-vm-1 → logic-vm SSH (internal, should work)

> **Why it works:** Traffic from `web-vm-1` (already inside the VNet) to `logic-vm` port 22 is evaluated against `nsg-web`. Traffic originates within the `VirtualNetwork`, which matches `allow-bastion-ssh-logic` (priority 210): `VirtualNetwork` → `asg-logic` port 22. Bastion is not involved here — any VM inside the VNet can act as a jump host.

From a Bastion session on `web-vm-1`:

```bash
LOGIC_IP=<logic-vm private IP>
ssh azureuser@$LOGIC_IP
# Logs in — VirtualNetwork → asg-logic port 22 is allowed ✅
```

### ✅ web-vm-1 → db-vm SSH (internal, should work)

> **Why it works:** Traffic from `web-vm-1` to `db-vm` crosses into `db-subnet`, so `nsg-db` is evaluated. The source is within the `VirtualNetwork`, which matches `allow-bastion-ssh-db` (priority 200): `VirtualNetwork` → `asg-db` port 22. The `deny-web-to-db` rule (priority 300) does deny `asg-web` → `asg-db` on all ports, but priority 200 is evaluated first and allows port 22 through before that rule is ever reached.

From a Bastion session on `web-vm-1`:

```bash
DB_IP=<db-vm private IP>
ssh azureuser@$DB_IP
# Logs in — VirtualNetwork → asg-db port 22 allowed at priority 200,
# before deny-web-to-db at priority 300 is even reached ✅
```

---

## 2. HTTP / database tier tests

Now that you can SSH into each VM, verify the inter-tier rules.

### ✅ Internet → web tier (should work)

> **Why it works:** `nsg-web` has rule `allow-internet-to-web` (priority 100) that explicitly permits inbound traffic from the `Internet` service tag to any NIC in `asg-web` on port 80. The web VMs' NICs are assigned to `asg-web`, so the rule matches.

```bash
curl http://$WEB_IP        # Node.js demo page
```

### ✅ web → logic tier (should work)

> **Why it works:** `nsg-web` has rule `allow-web-to-logic` (priority 110) that permits traffic from `asg-web` to `asg-logic` on port 3000. Both NICs are in the same subnet, so only `nsg-web` is evaluated. The rule matches because the source NIC is in `asg-web` and the destination NIC is in `asg-logic`.

From a Bastion session on `web-vm-1`:

```bash
LOGIC_IP=<logic-vm private IP>
curl http://$LOGIC_IP:3000/api/message
# {"message":"Hello from the logic tier!","hostname":"logic-vm",...}
```

### ❌ web → db tier (should be blocked)

> **Why it's blocked:** `nsg-db` has rule `deny-web-to-db` (priority 300) that explicitly denies all traffic from `asg-web` to `asg-db`. Even though the default Azure rule would allow VNet-internal traffic, this explicit deny at priority 300 takes precedence over the built-in `AllowVnetInBound` rule at priority 65000.

From inside `web-vm-1`:

```bash
DB_IP=<db-vm private IP>
curl --connect-timeout 5 http://$DB_IP:5432
# curl: (28) Connection timed out — blocked by nsg-db deny-web-to-db ✅
```

### ✅ logic → db tier (should work)

> **Why it works:** `nsg-db` has rule `allow-logic-to-db` (priority 100) that permits traffic from `asg-logic` to `asg-db` on port 5432. The `deny-web-to-db` rule at priority 300 doesn't apply here because the source NIC belongs to `asg-logic`, not `asg-web`.

From a Bastion session on `logic-vm`:

```bash
DB_IP=<db-vm private IP>
psql -h $DB_IP -U postgres -c "SELECT version();"
# Password: demo1234
# Returns PostgreSQL version — connection allowed ✅
```

### ❌ Direct internet → logic tier (should be blocked)

> **Why it's blocked:** `nsg-web` has rule `deny-internet-to-logic` (priority 300) that explicitly denies all inbound internet traffic to `asg-logic`. The logic VM has no public IP, but even if traffic somehow reached the subnet, this rule would drop it before the `deny-all-inbound` catch-all at priority 4000 gets a chance to evaluate.

```bash
curl --connect-timeout 5 http://$WEB_IP:3000
# Connection timed out — blocked by nsg-web deny-internet-to-logic ✅
```

---

## 3. NIC-level NSG tests

`logic-vm` has an additional NIC-level NSG (`nsg-nic-logic-vm`) that denies
outbound traffic to the `Internet` service tag. This is evaluated **after** any
outbound check at the subnet level, and restricts only this one VM — web-vm-1
and web-vm-2 in the same subnet are unaffected.

### ❌ logic-vm → Internet (should be blocked)

> **Why it's blocked:** Outbound evaluation is NIC NSG first, then subnet NSG. The NIC NSG `nsg-nic-logic-vm` has `deny-outbound-internet` at priority 100 denying everything to the `Internet` service tag. The subnet NSG `nsg-web` doesn't restrict outbound, so without the NIC NSG this would succeed — but the NIC NSG adds the restriction that the subnet doesn't.

From a Bastion session on `logic-vm`:

```bash
curl --connect-timeout 5 https://www.google.com
# curl: (28) Connection timed out — blocked by nsg-nic-logic-vm deny-outbound-internet ✅
```

### ✅ web-vm-1 → Internet (should work)

> **Why it works:** web-vm-1 has no NIC NSG. Outbound evaluation runs only through the subnet NSG `nsg-web`, which doesn't restrict outbound, so the default Azure outbound rule `AllowInternetOutBound` (priority 65001) allows the traffic.

From a Bastion session on `web-vm-1`:

```bash
curl --connect-timeout 5 https://www.google.com
# Returns HTML — no NIC NSG on this VM ✅
```

### ✅ logic-vm → db-vm (should still work)

> **Why it works:** The NIC NSG only denies outbound to `Internet`. Traffic to `db-vm` is within the VNet, which is allowed by the default outbound rule `AllowVnetOutBound` (priority 65000). Both the NIC NSG and subnet NSG permit it.

From a Bastion session on `logic-vm`:

```bash
psql -h $DB_IP -U postgres -c "SELECT 1;"
# Returns result — NIC NSG only blocks internet-bound traffic, not VNet traffic ✅
```

### Key takeaways

- **NIC NSGs stack on top of subnet NSGs** — both must allow for traffic to pass.
- **NIC NSGs can add restrictions** that the subnet NSG doesn't have (like this outbound internet deny).
- **NIC NSGs cannot override a subnet DENY** — if `nsg-web` had denied the traffic, no NIC-level allow could bring it back.
- **Use NIC NSGs for per-VM hardening** — one backend VM can have tighter rules without touching the subnet NSG that applies to siblings.

---

## 4. Debugging with Network Watcher

The ASG topology is a useful playground for Network Watcher because it stacks
multiple security layers: subnet NSGs, ASG-based rules, and a NIC-level NSG on
`logic-vm`. That makes the "which layer dropped my packet?" question
non-trivial, which is exactly when these tools earn their keep.

### Tool quick reference

| Tool | Use when | Needs infra |
|---|---|---|
| **IP Flow Verify** | "Would an NSG block this specific packet?" Y/N + matching rule | None |
| **NSG Diagnostics** | "Show me ALL effective NSG rules on this NIC" — merges subnet + NIC NSG | None |
| **Next Hop** | "Where would the packet route to?" — UDR / VNet / Internet / black hole | None |
| **Packet Capture** | "Show me the actual packet contents" — full `.cap`, max 5h | NetworkWatcherAgent extension on the VM |
| **Connection Monitor** | "Track latency / packet loss over time" | AMA + Log Analytics — see `network-monitoring/` |
| **Flow Logs / Traffic Analytics** | "Aggregate flow data over time" | Storage + workspace — see `network-monitoring/` |

Prerequisite (one-off per region):
```bash
az network watcher configure --enabled true --locations $LOCATION
```

### 4.1 IP Flow Verify — predict, then check

Use the existing rules to predict the outcome, then verify with the tool.
Each query returns `Allow` or `Deny` plus the matching `ruleName`.

```bash
WEB_VM_1_IP=10.0.1.10
WEB_VM_2_IP=10.0.1.11
LOGIC_IP=10.0.1.20
DB_IP=10.0.2.10
```

```bash
# 1) web-vm-1 → logic-vm:3000  (predict: Allow — allow-web-to-logic)
az network watcher test-ip-flow \
  -g $RG --vm logic-vm \
  --direction Inbound --protocol TCP \
  --local  $LOGIC_IP:3000 \
  --remote $WEB_VM_1_IP:54321

# 2) web-vm-1 → db-vm:5432     (predict: Deny — deny-web-to-db)
az network watcher test-ip-flow \
  -g $RG --vm db-vm \
  --direction Inbound --protocol TCP \
  --local  $DB_IP:5432 \
  --remote $WEB_VM_1_IP:54321

# 3) logic-vm → db-vm:5432     (predict: Allow — allow-logic-to-db)
az network watcher test-ip-flow \
  -g $RG --vm db-vm \
  --direction Inbound --protocol TCP \
  --local  $DB_IP:5432 \
  --remote $LOGIC_IP:54321

# 4) web-vm-1 → db-vm:22       (predict: Allow at priority 200 BEFORE deny-web-to-db at 300)
az network watcher test-ip-flow \
  -g $RG --vm db-vm \
  --direction Inbound --protocol TCP \
  --local  $DB_IP:22 \
  --remote $WEB_VM_1_IP:54321
```

Query 4 is the interesting one — both an Allow rule (priority 200) and a Deny
rule (priority 300) match. Lower priority wins, so the answer is Allow.
This is exactly the behaviour the SSH test in section 1 demonstrated.

### 4.2 NSG Diagnostics — see the merged effective ruleset

`logic-vm` has TWO NSGs in the path: the subnet NSG (`nsg-web`) and a NIC NSG
(`nsg-nic-logic-vm`). When debugging, you want the *combined* picture.

```bash
az network watcher show-security-group-view -g $RG --vm logic-vm
```

The output groups rules by source: `subnet` (`nsg-web`) and
`networkInterface` (`nsg-nic-logic-vm`), with both default and custom rules.
This is how you discover that the outbound-internet deny lives at the NIC,
not the subnet.

For comparison, run the same command against `web-vm-1` — you'll see only
the subnet NSG, because there's no NIC-level NSG on that VM.

### 4.3 Next Hop — where does routing send my packet?

Next Hop tells you the *route table decision*, not the NSG decision. It's
useful for diagnosing UDR, peering, or "missing default route" issues.

```bash
# web-vm-1 → 8.8.8.8 (predict: Internet)
az network watcher show-next-hop \
  -g $RG --vm web-vm-1 \
  --source-ip $WEB_VM_1_IP --dest-ip 8.8.8.8

# web-vm-1 → logic-vm (predict: VnetLocal — same VNet)
az network watcher show-next-hop \
  -g $RG --vm web-vm-1 \
  --source-ip $WEB_VM_1_IP --dest-ip $LOGIC_IP

# web-vm-1 → db-vm (predict: VnetLocal — different subnet, same VNet)
az network watcher show-next-hop \
  -g $RG --vm web-vm-1 \
  --source-ip $WEB_VM_1_IP --dest-ip $DB_IP
```

Note: even when an NSG would deny the traffic (e.g. web-vm-1 → db-vm), Next
Hop still says `VnetLocal` — routing and security are independent layers.

### 4.4 Packet Capture (optional — needs the agent extension)

Packet capture on Linux VMs requires the Network Watcher Agent extension.
Install it once per VM you want to capture from:

```bash
az vm extension set \
  -g $RG --vm-name web-vm-1 \
  --name NetworkWatcherAgentLinux \
  --publisher Microsoft.Azure.NetworkWatcher
```

Capture 60 seconds of traffic to a local file on the VM:
```bash
az network watcher packet-capture create \
  -g $RG --vm web-vm-1 \
  --name web-vm-1-capture \
  --file-path "/tmp/capture.cap" \
  --time-limit 60
```

While running, generate traffic from another Bastion session, then download
the `.cap` from `/tmp/capture.cap` via Bastion's file-transfer feature and
open in Wireshark.

---

## 5. Break it and debug it

These exercises change the live setup, then ask which Network Watcher tool
diagnoses the breakage.

### Exercise A — Stop the target VM

```bash
az vm deallocate -g $RG -n logic-vm
```

From `web-vm-1` (Bastion):
```bash
curl --connect-timeout 5 http://10.0.1.20:3000/api/message
# Connection refused / timed out
```

Now check with IP Flow Verify:
```bash
az network watcher test-ip-flow -g $RG --vm logic-vm \
  --direction Inbound --protocol TCP \
  --local 10.0.1.20:3000 --remote 10.0.1.10:54321
# Result: Allow — allow-web-to-logic
```

> **Lesson:** IP Flow Verify only evaluates against the **NSG rule set** —
> it doesn't probe the actual VM. If the NSG says Allow but traffic fails,
> the issue is at the host (VM stopped, service not listening, OS firewall).
> Use **Connection Monitor** (network-monitoring/ project) for actual
> reachability over time.

Restart:
```bash
az vm start -g $RG -n logic-vm
```

### Exercise B — Remove ASG membership

ASG-based rules only match traffic from NICs that are in the ASG. Strip
`web-vm-2` out of `asg-web`:

```bash
ASG_WEB_ID=$(az network asg show -g $RG -n asg-web --query id -o tsv)

# Remove the ASG association
az network nic ip-config update \
  -g $RG --nic-name web-vm-2-nic --name ipconfig1 \
  --application-security-groups ""
```

From `web-vm-2` (Bastion):
```bash
curl --connect-timeout 5 http://10.0.1.20:3000/api/message
# Times out
```

Diagnose with IP Flow Verify (note we use web-vm-2's IP as the remote):
```bash
az network watcher test-ip-flow -g $RG --vm logic-vm \
  --direction Inbound --protocol TCP \
  --local 10.0.1.20:3000 --remote 10.0.1.11:54321
# Result: Deny — deny-all-inbound at priority 4000
```

> **Why:** `allow-web-to-logic` (priority 110) requires the source NIC to be
> in `asg-web`. web-vm-2 isn't anymore, so no rule matches and traffic falls
> through to the priority-4000 deny.

Restore:
```bash
az network nic ip-config update \
  -g $RG --nic-name web-vm-2-nic --name ipconfig1 \
  --application-security-groups $ASG_WEB_ID
```

### Exercise C — Add a higher-priority deny

ASG rules show their power *and* their pitfalls when you add a new rule.

```bash
ASG_WEB_ID=$(az network asg show -g $RG -n asg-web --query id -o tsv)
ASG_LOGIC_ID=$(az network asg show -g $RG -n asg-logic --query id -o tsv)

# Add a deny at priority 50 (lower number = higher priority)
az network nsg rule create \
  -g $RG --nsg-name nsg-web \
  -n surprise-deny \
  --priority 50 --access Deny \
  --source-asgs $ASG_WEB_ID \
  --destination-asgs $ASG_LOGIC_ID \
  --destination-port-ranges 3000 \
  --protocol Tcp
```

From `web-vm-1`:
```bash
curl --connect-timeout 5 http://10.0.1.20:3000/api/message
# Times out — but which rule did it?
```

IP Flow Verify pinpoints it:
```bash
az network watcher test-ip-flow -g $RG --vm logic-vm \
  --direction Inbound --protocol TCP \
  --local 10.0.1.20:3000 --remote 10.0.1.10:54321
# Result: Deny — surprise-deny at priority 50
```

NSG Diagnostics confirms the rule is in the effective set:
```bash
az network watcher show-security-group-view -g $RG --vm logic-vm \
  --query "networkInterfaces[0].securityRuleAssociations.subnetAssociation.effectiveSecurityRules[?name=='UserRule_surprise-deny']"
```

Cleanup:
```bash
az network nsg rule delete -g $RG --nsg-name nsg-web -n surprise-deny
```

### Exercise D — NIC NSG masking the subnet NSG

Try to ping `8.8.8.8` from `logic-vm`:
```bash
ping -c 2 -W 2 8.8.8.8
# 100% packet loss
```

The subnet NSG `nsg-web` doesn't restrict outbound, so a quick check there
would say "this should work". But running NSG Diagnostics on `logic-vm`
shows the merged ruleset — including the NIC NSG `nsg-nic-logic-vm`:

```bash
az network watcher show-security-group-view -g $RG --vm logic-vm \
  --query "networkInterfaces[0].securityRuleAssociations.networkInterfaceAssociation"
```

You'll find `deny-outbound-internet` at priority 100 sitting on the NIC,
overriding the default `AllowInternetOutBound`.

> **Lesson:** when debugging outbound traffic, always check **both layers**.
> A subnet NSG might say "allowed" while a NIC NSG silently drops the packet.

---

## Why ASGs beat IP-based rules

Without ASGs, adding a third web VM means finding its IP and updating every NSG rule that references the web tier. With ASGs, you just assign the NIC to `asg-web` and all rules apply automatically.

## Clean up

```bash
az group delete --name $RG --yes
```
