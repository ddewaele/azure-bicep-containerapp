# Windows Hybrid — on-prem simulation + Azure File Sync + Entra Connect

Simulates an on-prem environment (Windows Server 2022 DC inside a dedicated
VNet) and demonstrates hybrid scenarios:

- **Azure File Sync** — local file server stays in sync with an Azure Files share
- **Entra Connect** — AD users synced into an Entra ID tenant
- **Private connectivity** — peered VNets + private endpoint so the DC reaches
  Azure Files over the Microsoft backbone, not the public internet
- **Mounting Azure Files** — SMB mount on the Windows Server

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│ "On-prem" VNet  10.10.0.0/16                                      │
│                                                                    │
│  ┌──────────────────────────────────┐       ┌──────────────────┐  │
│  │  dc-vm (Windows Server 2022)     │       │ Bastion Developer│  │
│  │    • AD DS — corp.local          │◄──────│  (browser RDP)   │  │
│  │    • Azure File Sync agent       │       │  free, built-in  │  │
│  │    • D:\SyncedData ──► Azure     │       └──────────────────┘  │
│  │    • Public IP (direct RDP)      │◄─── mstsc from your laptop  │
│  └──────────────────────────────────┘                              │
│                  │                                                 │
└──────────────────┼─────────────── peered ─────────────────────────┘
                   │
┌──────────────────┼─────────────────────────────────────────────────┐
│ Azure VNet  10.20.0.0/16           │                               │
│                                    ▼                               │
│  ┌───────────────────────────────────────────────────┐             │
│  │  Private endpoint (pe-subnet)                      │             │
│  │    → Storage Account                               │             │
│  │        • Azure File Share: hybrid-share            │             │
│  │    → privatelink.file.core.windows.net DNS zone    │             │
│  └───────────────────────────────────────────────────┘             │
│                                                                    │
│  Storage Sync Service  ── Sync Group ── Cloud Endpoint             │
│                                          └── Server Endpoint       │
│                                               (registered on dc-vm)│
└────────────────────────────────────────────────────────────────────┘

                           (manual step)
  dc-vm ───► Entra Connect MSI ───► syncs corp.local users to Entra ID
```

## Cost

| Component | Monthly |
|---|---|
| Windows VM (B2s) + Windows Server license | ~$120 |
| Bastion Developer | $0 |
| Storage + File Sync | ~$5 |
| Private endpoint | ~$7 |
| **Total** | **~$130-150** |

Entra Connect is free. Delete the resource group when done to stop all charges.

## Project structure

```
windows-hybrid/
├── 01-onprem-vnet.bicep       # On-prem VNet + Windows Server VM + Bastion
├── 02-azure-vnet.bicep        # Azure VNet + bidirectional peering
├── 03-file-sync.bicep         # Storage + File Share + sync service + private endpoint
├── parameters/
│   ├── 01-onprem-vnet.json
│   ├── 02-azure-vnet.json
│   └── 03-file-sync.json
├── scripts/
│   ├── setup-adds.ps1             # Promote dc-vm to DC (creates corp.local)
│   ├── seed-users.ps1             # Create OU=Demo + alice, bob
│   ├── install-filesync-agent.ps1 # Install Azure File Sync agent on dc-vm
│   └── mount-azure-files.ps1      # Mount file share via SMB + storage key
└── docs/
    └── entra-connect.md           # Manual Entra Connect install guide
```

---

## Deploy

```bash
LOCATION=eastus
RG=rg-windows-hybrid

az group create --name $RG --location $LOCATION
```

### Step 1 — On-prem VNet + Windows VM

> Windows admin password must be 12+ chars with upper/lower/digit/special.
>
> **Security note:** by default `rdpSourceAddressPrefix` is `*` (any). RDP from
> the public internet is a high-exposure configuration. For anything beyond a
> short-lived demo, set it to your own public IP (e.g. `"$(curl -s ifconfig.me)/32"`).

```bash
az deployment group create \
  --resource-group $RG \
  --template-file 01-onprem-vnet.bicep \
  --parameters @parameters/01-onprem-vnet.json \
  --parameters adminPassword='<YourStrongPassword>' \
  --parameters rdpSourceAddressPrefix="$(curl -s ifconfig.me)/32"
```

This creates `onprem-vnet`, the Windows VM `dc-vm`, a Standard public IP for
direct RDP, and Bastion (as a fallback). Takes ~5 minutes.

Grab the public IP:
```bash
DC_PUBLIC_IP=$(az deployment group show -g $RG -n 01-onprem-vnet \
  --query properties.outputs.dcPublicIp.value -o tsv)
echo "RDP target: $DC_PUBLIC_IP"
```

### Step 2 — Promote dc-vm to a domain controller

Two options to connect:
- **Direct RDP**: `mstsc /v:$DC_PUBLIC_IP` — sign in as `azureadmin`.
- **Bastion**: Portal → `dc-vm` → **Connect → Bastion** → sign in as `azureadmin`.
2. Open an elevated PowerShell prompt.
3. Copy the contents of `scripts/setup-adds.ps1` into the shell (or upload the
   file and run it).
4. Enter a DSRM (Directory Services Restore Mode) password when prompted.
5. Wait ~10 minutes. The VM reboots when done.
6. RDP back in (you'll sign in as `CORP\azureadmin` now).
7. Run `scripts/seed-users.ps1` to create `OU=Demo` with `alice` and `bob`.

### Step 3 — Azure VNet + peering

```bash
az deployment group create \
  --resource-group $RG \
  --template-file 02-azure-vnet.bicep \
  --parameters @parameters/02-azure-vnet.json
```

### Step 4 — Storage + File Sync infrastructure

```bash
az deployment group create \
  --resource-group $RG \
  --template-file 03-file-sync.bicep \
  --parameters @parameters/03-file-sync.json

# Capture deployment outputs for the next steps
STORAGE=$(az deployment group show -g $RG -n 03-file-sync \
  --query properties.outputs.storageAccountName.value -o tsv)
SHARE=$(az deployment group show -g $RG -n 03-file-sync \
  --query properties.outputs.fileShareName.value -o tsv)
SYNC_SVC=$(az deployment group show -g $RG -n 03-file-sync \
  --query properties.outputs.syncServiceName.value -o tsv)
SYNC_GROUP=$(az deployment group show -g $RG -n 03-file-sync \
  --query properties.outputs.syncGroupName.value -o tsv)

echo "Storage: $STORAGE"
echo "Share:   $SHARE"
```

### Step 5 — Create the cloud endpoint

The cloud endpoint links the sync group to the Azure file share. Requires the
`Microsoft.StorageSync` service principal to have **Reader and Data Access** on
the storage account — granted automatically on first use in most tenants.

```bash
az storagesync sync-group cloud-endpoint create \
  --resource-group             $RG \
  --storage-sync-service       $SYNC_SVC \
  --sync-group-name            $SYNC_GROUP \
  --name                       cloud-endpoint \
  --storage-account            $STORAGE \
  --azure-file-share-name      $SHARE
```

> If this fails with an authorization error, grant the role manually:
> ```bash
> STORAGE_ID=$(az storage account show -g $RG -n $STORAGE --query id -o tsv)
> SYNC_SP=$(az ad sp list --display-name 'Microsoft.StorageSync' --query '[0].id' -o tsv)
> az role assignment create --assignee $SYNC_SP \
>   --role 'Reader and Data Access' --scope $STORAGE_ID
> ```

### Step 6 — Install File Sync agent + register the server

Back on `dc-vm` (via Bastion):

```powershell
# Run scripts/install-filesync-agent.ps1
# When the Server Registration UI launches, sign in and select $SYNC_SVC
```

### Step 7 — Create a server endpoint

Create a local folder to sync, then register it as a server endpoint.

```powershell
# On dc-vm
New-Item -Path 'D:\SyncedData' -ItemType Directory -Force
```

Then from your dev machine:

```bash
SERVER_ID=$(az storagesync registered-server list \
  --resource-group $RG \
  --storage-sync-service $SYNC_SVC \
  --query '[0].id' -o tsv)

az storagesync sync-group server-endpoint create \
  --resource-group        $RG \
  --storage-sync-service  $SYNC_SVC \
  --sync-group-name       $SYNC_GROUP \
  --name                  dc-vm-endpoint \
  --registered-server     $SERVER_ID \
  --server-local-path     'D:\SyncedData' \
  --cloud-tiering          false
```

### Step 8 — Test sync both directions

On `dc-vm`:
```powershell
"Hello from on-prem" | Out-File 'D:\SyncedData\from-onprem.txt'
```

From your dev machine (give it a minute to sync):
```bash
az storage file list \
  --account-name $STORAGE \
  --share-name $SHARE \
  --output table
```

Upload from the cloud side:
```bash
echo "Hello from the cloud" > from-cloud.txt
az storage file upload \
  --account-name $STORAGE \
  --share-name $SHARE \
  --source from-cloud.txt
```

Back on `dc-vm`, run `dir D:\SyncedData` — both files should appear.

### Step 9 — Mount the file share on dc-vm

Mount `Z:` directly on the Windows VM (in addition to the sync):

```powershell
# Fetch the storage key
$StorageKey = '<from: az storage account keys list -g $RG -n $STORAGE>'

.\scripts\mount-azure-files.ps1 `
  -StorageAccount 'hybsyncxxxxxxxx' `
  -ShareName      'hybrid-share' `
  -StorageKey     $StorageKey `
  -DriveLetter    'Z'

dir Z:
```

Because the DC is peered to the Azure VNet **and** the private DNS zone is
linked to the on-prem VNet, the UNC path `\\<storage>.file.core.windows.net`
resolves to a **private IP** (10.20.2.x) — SMB traffic never leaves the VNet.

Verify with:
```powershell
Resolve-DnsName "<storage>.file.core.windows.net"
# Should show a 10.20.2.x address, not a public IP
```

### Step 10 — (Optional) Entra Connect

See [`docs/entra-connect.md`](docs/entra-connect.md) for the manual install
walkthrough. Syncs `alice` and `bob` from `OU=Demo` into your Entra tenant.

> Read the warning at the top of that file first — this modifies your real
> Entra tenant.

---

## Why these choices

**Why simulate on-prem inside Azure?**
A real on-prem lab needs Hyper-V, a physical host, and VPN setup. A separate
VNet with no peering to Azure services is functionally equivalent: it's
isolated by default, forces you to peer/VPN/private-endpoint to reach Azure,
and tears down with one `az group delete`.

**Why Bastion Developer instead of Basic/Standard?**
Browser-based RDP is enough for this demo. Developer SKU is free; Basic is
~$140/mo and still browser-only; Standard (~$280/mo) adds native client
(`az network bastion rdp`) which we don't need.

**Why manual AD DS setup instead of a Custom Script Extension?**
Promoting to DC requires a reboot mid-script. CSE doesn't handle that
gracefully. PowerShell DSC does but adds a lot of complexity. For a
learning project, "RDP in and run this script" is clearer than a
DSC-based one-shot.

**Why private endpoint + private DNS zone?**
Without it, `\\<storage>.file.core.windows.net` resolves to a public IP and
SMB traffic traverses the internet (allowed but not private). The private
endpoint + DNS zone makes the UNC path resolve to a VNet-local IP so all
traffic stays on the Microsoft backbone.

## Tear down

```bash
az group delete --name $RG --yes
```

> Reminder: resource group deletion does **not** remove synced users from Entra.
> Delete those manually (see `docs/entra-connect.md`).
