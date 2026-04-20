# Application Security Groups (ASG)

Demonstrates how **Application Security Groups** let you write NSG rules using logical tier names (`asg-web`, `asg-logic`, `asg-db`) instead of IP addresses. Adding a new VM to a tier only requires assigning its NIC to the right ASG — no rule changes needed.

## Architecture

```
VIRTUAL NETWORK  10.0.0.0/16
│
├── web-subnet  10.0.1.0/24  ── nsg-web
│     ├── web-vm-1  NIC → asg-web    (nginx :80, public IP)
│     ├── web-vm-2  NIC → asg-web    (nginx :80)
│     └── logic-vm  NIC → asg-logic  (Node.js :3000)
│
└── db-subnet   10.0.2.0/24  ── nsg-db
      └── db-vm   NIC → asg-db     (PostgreSQL :5432)
```

## NSG rules

### nsg-web

| Priority | Name | Source | Destination | Port | Action |
|---|---|---|---|---|---|
| 100 | allow-internet-to-web | Internet | `asg-web` | 80 | Allow ✅ |
| 110 | allow-web-to-logic | `asg-web` | `asg-logic` | 3000 | Allow ✅ |
| 200 | allow-bastion-ssh-web | VirtualNetwork | `asg-web` | 22 | Allow ✅ |
| 210 | allow-bastion-ssh-logic | VirtualNetwork | `asg-logic` | 22 | Allow ✅ |
| 300 | deny-internet-to-logic | Internet | `asg-logic` | * | Deny ❌ |
| 4000 | deny-all-inbound | * | * | * | Deny ❌ |

### nsg-db

| Priority | Name | Source | Destination | Port | Action |
|---|---|---|---|---|---|
| 100 | allow-logic-to-db | `asg-logic` | `asg-db` | 5432 | Allow ✅ |
| 200 | allow-bastion-ssh-db | VirtualNetwork | `asg-db` | 22 | Allow ✅ |
| 300 | deny-web-to-db | `asg-web` | `asg-db` | * | Deny ❌ |
| 4000 | deny-all-inbound | * | * | * | Deny ❌ |

## Deploy

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

### ✅ Internet → web tier (should work)

```bash
WEB_IP=$(az deployment group show -g $RG -n 02-vms \
  --query properties.outputs.webVm1PublicIp.value -o tsv)

curl http://$WEB_IP        # nginx default page
```

### ✅ web → logic tier (should work)

SSH into `web-vm-1` via Bastion (Portal → web-vm-1 → Connect → Bastion):

```bash
LOGIC_IP=<logic-vm private IP>
curl http://$LOGIC_IP:3000/api/message
# {"message":"Hello from the logic tier!","hostname":"logic-vm",...}
```

### ❌ web → db tier (should be blocked)

From inside `web-vm-1`:

```bash
DB_IP=<db-vm private IP>
curl --connect-timeout 5 http://$DB_IP:5432
# curl: (28) Connection timed out — blocked by nsg-db deny-web-to-db ✅
```

### ✅ logic → db tier (should work)

SSH into `logic-vm` via Bastion:

```bash
DB_IP=<db-vm private IP>
psql -h $DB_IP -U postgres -c "SELECT version();"
# Password: demo1234
# Returns PostgreSQL version — connection allowed ✅
```

### ❌ Direct internet → logic tier (should be blocked)

```bash
curl --connect-timeout 5 http://$WEB_IP:3000
# Connection timed out — blocked by nsg-web deny-internet-to-logic ✅
```

## Why ASGs beat IP-based rules

Without ASGs, adding a third web VM means finding its IP and updating every NSG rule that references the web tier. With ASGs, you just assign the NIC to `asg-web` and all rules apply automatically.

## Clean up

```bash
az group delete --name $RG --yes
```
