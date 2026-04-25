// =============================================================================
// Step 1 — Network: VNet, subnets, ASGs, NSGs
//
// Creates the full network topology for the ASG demo:
//
//   web-subnet  10.0.1.0/24  ── nsg-web  (web-vm-1, web-vm-2, logic-vm)
//   db-subnet   10.0.2.0/24  ── nsg-db   (db-vm)
//
// ASGs:
//   asg-web    — assigned to web VM NICs
//   asg-logic  — assigned to logic VM NIC
//   asg-db     — assigned to db VM NIC
//
// NSG rules use ASGs as source/destination instead of IPs, so adding a new
// VM to a tier only requires assigning its NIC to the right ASG — no rule edits.
//
// Usage:
//   az deployment group create \
//     --resource-group rg-asg-demo \
//     --template-file 01-network.bicep \
//     --parameters @parameters/01-network.json
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

// ---------------------------------------------------------------------------
// Application Security Groups — one per tier
// ---------------------------------------------------------------------------
resource asgWeb 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = {
  name: 'asg-web'
  location: location
}

resource asgLogic 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = {
  name: 'asg-logic'
  location: location
}

resource asgDb 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = {
  name: 'asg-db'
  location: location
}

// ---------------------------------------------------------------------------
// NSG: web-subnet
//
// Rules (evaluated in priority order, lower = first):
//   100  Allow Internet      → asg-web   : 80    (public web access)
//   110  Allow asg-web       → asg-logic : 3000  (web calls logic API)
//   200  Allow VirtualNetwork → asg-web  : 22    (Bastion SSH to web VMs)
//   210  Allow VirtualNetwork → asg-logic: 22    (Bastion SSH to logic VM)
//   300  Deny  Internet      → asg-logic : *     (block direct internet to logic)
//  4000  Deny  *             → *         : *     (override built-in VNet allow)
// ---------------------------------------------------------------------------
resource nsgWeb 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-web'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-internet-to-web'
        properties: {
          priority:                    100
          protocol:                    'Tcp'
          access:                      'Allow'
          direction:                   'Inbound'
          sourceAddressPrefix:         'Internet'
          sourcePortRange:             '*'
          destinationApplicationSecurityGroups: [{ id: asgWeb.id }]
          destinationPortRange:        '80'
        }
      }
      {
        name: 'allow-web-to-logic'
        properties: {
          priority:                    110
          protocol:                    'Tcp'
          access:                      'Allow'
          direction:                   'Inbound'
          sourceApplicationSecurityGroups:      [{ id: asgWeb.id }]
          sourcePortRange:             '*'
          destinationApplicationSecurityGroups: [{ id: asgLogic.id }]
          destinationPortRange:        '3000'
        }
      }
      {
        name: 'allow-bastion-ssh-web'
        properties: {
          priority:                    200
          protocol:                    'Tcp'
          access:                      'Allow'
          direction:                   'Inbound'
          sourceAddressPrefix:         'VirtualNetwork'
          sourcePortRange:             '*'
          destinationApplicationSecurityGroups: [{ id: asgWeb.id }]
          destinationPortRange:        '22'
        }
      }
      {
        name: 'allow-bastion-ssh-logic'
        properties: {
          priority:                    210
          protocol:                    'Tcp'
          access:                      'Allow'
          direction:                   'Inbound'
          sourceAddressPrefix:         'VirtualNetwork'
          sourcePortRange:             '*'
          destinationApplicationSecurityGroups: [{ id: asgLogic.id }]
          destinationPortRange:        '22'
        }
      }
      {
        name: 'deny-internet-to-logic'
        properties: {
          priority:                    300
          protocol:                    '*'
          access:                      'Deny'
          direction:                   'Inbound'
          sourceAddressPrefix:         'Internet'
          sourcePortRange:             '*'
          destinationApplicationSecurityGroups: [{ id: asgLogic.id }]
          destinationPortRange:        '*'
        }
      }
      {
        // Overrides the built-in AllowVnetInBound (65000) so only explicitly
        // allowed traffic gets through
        name: 'deny-all-inbound'
        properties: {
          priority:                 4000
          protocol:                 '*'
          access:                   'Deny'
          direction:                'Inbound'
          sourceAddressPrefix:      '*'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// NSG: db-subnet
//
// Rules:
//   100  Allow asg-logic → asg-db : 5432  (only logic tier can reach the DB)
//   200  Allow VirtualNetwork → asg-db : 22  (Bastion SSH to db VM)
//   300  Deny  asg-web   → asg-db : *     (web tier must not bypass logic tier)
//  4000  Deny  *         → *      : *     (override built-in VNet allow)
// ---------------------------------------------------------------------------
resource nsgDb 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-db'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-logic-to-db'
        properties: {
          priority:                    100
          protocol:                    'Tcp'
          access:                      'Allow'
          direction:                   'Inbound'
          sourceApplicationSecurityGroups:      [{ id: asgLogic.id }]
          sourcePortRange:             '*'
          destinationApplicationSecurityGroups: [{ id: asgDb.id }]
          destinationPortRange:        '5432'
        }
      }
      {
        name: 'allow-bastion-ssh-db'
        properties: {
          priority:                    200
          protocol:                    'Tcp'
          access:                      'Allow'
          direction:                   'Inbound'
          sourceAddressPrefix:         'VirtualNetwork'
          sourcePortRange:             '*'
          destinationApplicationSecurityGroups: [{ id: asgDb.id }]
          destinationPortRange:        '22'
        }
      }
      {
        name: 'deny-web-to-db'
        properties: {
          priority:                    300
          protocol:                    '*'
          access:                      'Deny'
          direction:                   'Inbound'
          sourceApplicationSecurityGroups:      [{ id: asgWeb.id }]
          sourcePortRange:             '*'
          destinationApplicationSecurityGroups: [{ id: asgDb.id }]
          destinationPortRange:        '*'
        }
      }
      {
        name: 'deny-all-inbound'
        properties: {
          priority:                 4000
          protocol:                 '*'
          access:                   'Deny'
          direction:                'Inbound'
          sourceAddressPrefix:      '*'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// NIC-level NSG for logic-vm
//
// Demonstrates NIC-level NSGs (vs the subnet-level NSGs above). Azure
// evaluates NSGs in order:
//   Inbound:  subnet NSG → NIC NSG → VM        (both must allow)
//   Outbound: NIC NSG → subnet NSG → wire      (both must allow)
//
// NIC NSGs can ADD restrictions beyond the subnet NSG but cannot override
// a subnet DENY. Here we use it to prevent logic-vm from making outbound
// calls to the internet — a common least-privilege hardening for backend
// services that only need to talk to their peers in the VNet.
//
// The subnet NSG does not restrict outbound, so this deny has no equivalent
// at the subnet level and cleanly demonstrates per-VM restrictions.
// ---------------------------------------------------------------------------
resource nsgNicLogic 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-nic-logic-vm'
  location: location
  properties: {
    securityRules: [
      {
        name: 'deny-outbound-internet'
        properties: {
          priority:                 100
          protocol:                 '*'
          access:                   'Deny'
          direction:                'Outbound'
          sourceAddressPrefix:      '*'
          sourcePortRange:          '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange:     '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// VNet — three subnets: web, db, and the dedicated Bastion subnet
// AzureBastionSubnet must be named exactly that and be at least /26
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'asg-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: 'web-subnet'
        properties: {
          addressPrefix:          '10.0.1.0/24'
          networkSecurityGroup:   { id: nsgWeb.id }
        }
      }
      {
        name: 'db-subnet'
        properties: {
          addressPrefix:          '10.0.2.0/24'
          networkSecurityGroup:   { id: nsgDb.id }
        }
      }
      {
        // Basic SKU Bastion requires a dedicated /26 (or larger) subnet
        // named exactly 'AzureBastionSubnet' — no NSG allowed on this subnet
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.0.3.0/26'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Azure Bastion — Standard SKU
// Requires a Standard public IP and the AzureBastionSubnet above.
// enableTunneling enables native client support (az network bastion ssh).
// Cost: ~$0.38/hr (~$280/month) — delete the resource group when done.
// ---------------------------------------------------------------------------
resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'asg-bastion-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: 'asg-bastion'
  location: location
  sku: { name: 'Standard' }
  properties: {
    enableTunneling: true
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          publicIPAddress: { id: bastionPip.id }
          subnet:          { id: '${vnet.id}/subnets/AzureBastionSubnet' }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output vnetId      string = vnet.id
output asgWebId    string = asgWeb.id
output asgLogicId  string = asgLogic.id
output asgDbId     string = asgDb.id
