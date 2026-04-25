# Azure Network Monitoring Lab

A hands-on sandbox for the **Monitor & Maintain** objective — DCE/DCR pipelines,
NSG Flow Logs, Traffic Analytics, and every Network Watcher tool.

Two Ubuntu VMs in separate subnets with mixed allow/deny NSG rules generate
flow log data that's interesting to query, and the monitoring stack
(Log Analytics + AMA via DCE/DCR) gives you a working end-to-end telemetry
pipeline to poke at.

## Architecture

```
netmon-vnet  10.50.0.0/16
│
├── vm1-subnet 10.50.1.0/24  ── nsg-vm1
│     └── vm1  (Ubuntu, public IP, AMA installed)
│
├── vm2-subnet 10.50.2.0/24  ── nsg-vm2
│     └── vm2  (Ubuntu, private only, AMA installed)
│
└── netmon-bastion (Developer SKU, free)

Monitoring pipeline:
   AMA agent ─► DCE ─► DCR ─► Log Analytics workspace
                                    ▲
   NSG Flow Logs v2 ─► Storage ─► Traffic Analytics ──┘
```

## NSG rules

### nsg-vm1 (on vm1-subnet)

| Priority | Name | Source | Dest | Port | Action |
|---|---|---|---|---|---|
| 100 | allow-vnet-ssh       | VirtualNetwork | * | 22 | Allow ✅ |
| 200 | allow-internet-http  | Internet       | * | 80 | Allow ✅ |
| 300 | allow-vnet-icmp      | VirtualNetwork | * | *  | Allow ✅ |
| 4000 | deny-all-inbound    | *              | * | *  | Deny ❌ |

### nsg-vm2 (on vm2-subnet)

| Priority | Name | Source | Dest | Port | Action |
|---|---|---|---|---|---|
| 100 | allow-vnet-ssh         | VirtualNetwork | * | 22 | Allow ✅ |
| 110 | allow-vm1subnet-icmp   | 10.50.1.0/24   | * | *  | Allow ✅ |
| 4000 | deny-all-inbound      | *              | * | *  | Deny ❌ |

The asymmetry (vm1 → vm2:22 allowed, vm1 → vm2:80 denied) is what makes every
Network Watcher tool show something meaningful.

## Cost

| Component | Monthly |
|---|---|
| 2× Ubuntu B2as_v2 | ~$60 |
| Bastion Developer | $0 |
| Log Analytics (small volume) | ~$5 |
| Storage (flow logs) | ~$1 |
| Traffic Analytics processing | ~$2/GB analyzed |
| **Total** | **~$70-80/mo** |

---

## Deploy

```bash
LOCATION=westeurope
RG=rg-netmon

az group create --name $RG --location $LOCATION

# Prerequisite — ensure Network Watcher is enabled for this region
az network watcher configure --enabled true --locations $LOCATION
```

### Step 1 — Network + VMs + Bastion

```bash
az deployment group create \
  --resource-group $RG \
  --template-file 01-network.bicep \
  --parameters @parameters/01-network.json \
  --parameters sshPublicKey="$(cat ~/.ssh/azure-cheap-vm/ed25519.pub)"
```

### Step 2 — Log Analytics + DCE + DCR + AMA

> **Exam trap:** the order matters. **DCE before DCR** (DCR references DCE),
> **DCR association before AMA** (agent reads rules on start), **AMA last**.
> Bicep enforces this via resource graph — don't fight it.

```bash
az deployment group create \
  --resource-group $RG \
  --template-file 02-monitoring.bicep \
  --parameters @parameters/02-monitoring.json
```

### Step 3 — NSG Flow Logs + Traffic Analytics

```bash
az deployment group create \
  --resource-group $RG \
  --template-file 03-flow-logs.bicep \
  --parameters @parameters/03-flow-logs.json

# Capture outputs for the walkthroughs below
STORAGE=$(az deployment group show -g $RG -n 03-flow-logs \
  --query properties.outputs.storageAccountName.value -o tsv)
WORKSPACE=$(az monitor log-analytics workspace show \
  -g $RG -n netmon-workspace --query customerId -o tsv)
VM1_ID=$(az vm show -g $RG -n vm1 --query id -o tsv)
VM2_ID=$(az vm show -g $RG -n vm2 --query id -o tsv)
```

### Step 4 — Generate traffic

Copy the traffic generator to vm1 and run it in a loop:

```bash
# From your dev machine:
scp -o ProxyCommand="az network bastion tunnel ..." scripts/generate-traffic.sh azureuser@vm1:~/

# Or (easier) paste the script into a Bastion SSH session.
# Then on vm1:
chmod +x generate-traffic.sh
./generate-traffic.sh     # runs until Ctrl-C, 30s cycle
```

Let it run for **at least 10 minutes** before the Traffic Analytics dashboard
has data — that's the minimum ingestion window.

---

## Network Watcher — one tool per section

### 1. IP Flow Verify — "is this NSG blocking this specific packet?"

Gives a Y/N answer and the matching rule name. Good for "did I write the NSG
rule correctly?" sanity checks. **Does not send real traffic** — it simulates
against the rule set.

```bash
# Check: can the Internet reach vm1 on port 80?    → expect Allow (allow-internet-http)
az network watcher test-ip-flow \
  --resource-group $RG \
  --vm vm1 \
  --direction Inbound \
  --protocol TCP \
  --local  10.50.1.10:80 \
  --remote 203.0.113.10:54321

# Check: can the Internet reach vm1 on port 22?    → expect Deny (no matching allow, hits 4000)
az network watcher test-ip-flow \
  --resource-group $RG \
  --vm vm1 \
  --direction Inbound \
  --protocol TCP \
  --local  10.50.1.10:22 \
  --remote 203.0.113.10:54321

# Check: can vm1 reach vm2 on port 80?             → expect Deny (no allow in nsg-vm2)
az network watcher test-ip-flow \
  --resource-group $RG \
  --vm vm2 \
  --direction Inbound \
  --protocol TCP \
  --local  10.50.2.10:80 \
  --remote 10.50.1.10:54321

# Check: can vm1 reach vm2 on port 22?             → expect Allow (allow-vnet-ssh)
az network watcher test-ip-flow \
  --resource-group $RG \
  --vm vm2 \
  --direction Inbound \
  --protocol TCP \
  --local  10.50.2.10:22 \
  --remote 10.50.1.10:54321
```

Output includes `ruleName` — this is the exact NSG rule that matched.

### 2. Next Hop — "where does this traffic actually go?"

Traces the effective route table to tell you the next hop type (VirtualNetwork,
Internet, VirtualNetworkGateway, None). Useful when debugging UDRs,
peering, or "why isn't my traffic reaching…".

```bash
# vm1 → 8.8.8.8       → next hop = Internet
az network watcher show-next-hop \
  --resource-group $RG \
  --vm vm1 \
  --source-ip 10.50.1.10 \
  --dest-ip 8.8.8.8

# vm1 → vm2 (10.50.2.10)  → next hop = VnetLocal (same VNet)
az network watcher show-next-hop \
  --resource-group $RG \
  --vm vm1 \
  --source-ip 10.50.1.10 \
  --dest-ip 10.50.2.10
```

### 3. NSG Flow Logs — raw 5-tuple data

After step 4 has been generating traffic for a few minutes, flow logs
accumulate as JSON blobs in the storage account. Each record is
`timestamp | src IP | dst IP | src port | dst port | protocol | direction | decision`.

```bash
# List blobs (organised by date)
az storage blob list \
  --account-name $STORAGE \
  --container-name insights-logs-networksecuritygroupflowevent \
  --query "[].name" -o tsv | tail -5

# Download the latest blob and pretty-print
BLOB=$(az storage blob list \
  --account-name $STORAGE \
  --container-name insights-logs-networksecuritygroupflowevent \
  --query "[-1].name" -o tsv)

az storage blob download \
  --account-name $STORAGE \
  --container-name insights-logs-networksecuritygroupflowevent \
  --name "$BLOB" --file /tmp/flow.json

jq '.records[0].properties.flows[0].flows[0].flowTuples' /tmp/flow.json
```

### 4. Traffic Analytics — KQL over the flow log data

Traffic Analytics writes to the `AzureNetworkAnalytics_CL` table in Log
Analytics. **First data appears ~10-30 minutes after flows happen.**

Open the workspace in Portal → Logs, or use the CLI:

```bash
# Top talkers (source IP → destination IP, sorted by flow count)
az monitor log-analytics query \
  --workspace $WORKSPACE \
  --analytics-query "
    AzureNetworkAnalytics_CL
    | where SubType_s == 'FlowLog'
    | summarize FlowCount = count() by SrcIP_s, DestIP_s, L4Protocol_s, DestPort_d
    | order by FlowCount desc
    | take 10
  "

# Denied flows only (what's being blocked?)
az monitor log-analytics query \
  --workspace $WORKSPACE \
  --analytics-query "
    AzureNetworkAnalytics_CL
    | where SubType_s == 'FlowLog' and FlowStatus_s == 'D'
    | project TimeGenerated, SrcIP_s, DestIP_s, DestPort_d, NSGRule_s
    | take 20
  "
```

### 5. Connection Monitor — ongoing connectivity/latency probes

Unlike IP Flow Verify (one-shot simulation), Connection Monitor **actually
sends probes** and records latency + reachability over time. Requires AMA
on the source and/or destination (we installed it in step 2).

> **Exam trap:** Connection Monitor v2 uses **Azure Monitor Agent**, not
> the legacy Log Analytics agent, and not the Network Performance Monitor
> solution. The old MMA-based approach is deprecated.

Easiest path is the Portal: Network Watcher → Connection Monitor → Create.
Or via CLI with a JSON spec:

```bash
# Minimal test: vm1 → vm2:22 (expect success) and vm1 → vm2:80 (expect blocked)
az network watcher connection-monitor create \
  --resource-group $RG \
  --name vm1-to-vm2 \
  --location $LOCATION \
  --endpoint-source-name vm1 \
  --endpoint-source-resource-id $VM1_ID \
  --endpoint-dest-name vm2 \
  --endpoint-dest-resource-id $VM2_ID \
  --test-config-name ssh-probe \
  --protocol Tcp \
  --tcp-port 22 \
  --frequency 30
```

View results in Portal → Network Watcher → Connection Monitor → vm1-to-vm2.
Latency over time + a "probe failed at NSG" annotation when a port is blocked.

### 6. Packet Capture — record traffic for up to 5 hours

Captures every packet in/out of a VM to a `.cap` file in storage. Useful when
flow logs give you the 5-tuple but you need the actual payload.

```bash
# Capture up to 5 min or 100 MB, whichever first
az network watcher packet-capture create \
  --resource-group $RG \
  --vm vm1 \
  --name vm1-capture \
  --storage-account $STORAGE \
  --time-limit 300 \
  --bytes-to-capture-per-packet 0

# While the capture is running, generate some traffic from vm2:
# (from vm2 via Bastion) ping 10.50.1.10; curl http://10.50.1.10

# Stop and wait for upload
az network watcher packet-capture stop \
  --location $LOCATION --name vm1-capture

# The .cap blob lands in the container: network-watcher-logs
az storage blob list \
  --account-name $STORAGE \
  --container-name network-watcher-logs \
  --query "[].name" -o tsv
```

Download and open in Wireshark.

---

## Cheat sheet — which tool when?

| Question | Tool |
|---|---|
| "Is my NSG rule blocking this packet?" | **IP Flow Verify** |
| "Where does traffic from A actually route to?" | **Next Hop** |
| "Show me every flow through this NSG." | **NSG Flow Logs** (raw JSON) |
| "Visualise / aggregate the flow data." | **Traffic Analytics** (KQL / Portal) |
| "Track connectivity + latency over time." | **Connection Monitor** (v2, needs AMA) |
| "Record actual packet contents for debugging." | **Packet Capture** (max 5h) |

## Clean up

```bash
az group delete --name $RG --yes

# Flow logs live in NetworkWatcherRG — delete them specifically if you don't
# want stale config left behind (the storage account they point to is gone,
# so they'll just error until removed):
az network watcher flow-log delete -g NetworkWatcherRG --location $LOCATION --name nsg-vm1-flowlog
az network watcher flow-log delete -g NetworkWatcherRG --location $LOCATION --name nsg-vm2-flowlog
```
