// =============================================================================
// Module: Container App (reusable for frontend and backend)
//
// Highlights:
//   - isExternalIngress=false  → private, internal-only (Security)
//   - isExternalIngress=true   → public HTTPS, HTTP→HTTPS redirect enforced
//   - Auto-scaling via HTTP concurrent requests  (Performance Efficiency)
//   - minReplicas=1 for predictable latency; set to 0 for max cost saving
// =============================================================================

@description('Unique name for this Container App (2–32 lowercase alphanumeric / hyphens).')
param name string

@description('Azure region.')
param location string

@description('Resource ID of the Container Apps Environment.')
param environmentId string

@description('Container image reference (registry/image:tag).')
param containerImage string

@description('Port the container listens on.')
param targetPort int = 80

@description('True → publicly accessible HTTPS endpoint. False → internal to the environment only.')
param isExternalIngress bool = false

@description('Environment variables injected into the container.')
param envVars array = []

// ---------------------------------------------------------------------------
// Registry credentials (optional — leave empty for public images)
// ---------------------------------------------------------------------------

@description('ACR login server, e.g. myregistry.azurecr.io. Leave empty for public images.')
param registryServer string = ''

@description('ACR admin username.')
param registryUsername string = ''

@description('ACR admin password.')
@secure()
param registryPassword string = ''

// ---------------------------------------------------------------------------
// Scale settings
// ---------------------------------------------------------------------------

@description('Minimum number of running replicas. Set to 0 to allow scale-to-zero.')
@minValue(0)
@maxValue(10)
param minReplicas int = 1

@description('Maximum number of replicas.')
@minValue(1)
@maxValue(10)
param maxReplicas int = 3

// ---------------------------------------------------------------------------
// Container App
// ---------------------------------------------------------------------------
resource app 'Microsoft.App/containerApps@2023-05-01' = {
  name: name
  location: location
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'

    configuration: {
      // Registry credentials — only included when a private registry is specified.
      // The password is stored as a Container App secret; the registries block references
      // it by name so the plain-text value is never written to the revision spec.
      secrets: registryServer != '' ? [
        {
          name: 'registry-password'
          value: registryPassword
        }
      ] : []

      registries: registryServer != '' ? [
        {
          server:            registryServer
          username:          registryUsername
          passwordSecretRef: 'registry-password'
        }
      ] : []

      ingress: {
        external: isExternalIngress
        targetPort: targetPort
        transport: 'auto'       // HTTP/1.1 + HTTP/2 via ALPN negotiation
        allowInsecure: false    // Security: HTTP requests are redirected to HTTPS
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }

    template: {
      containers: [
        {
          name: 'app'
          image: containerImage
          env: envVars
          resources: {
            // 0.25 vCPU / 0.5 GiB — smallest Consumption tier allocation
            // Cost Optimization: right-size for a demo workload
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          // Reliability: built-in liveness / readiness probes use HTTP GET on targetPort
          // (Container Apps applies defaults automatically — no explicit config needed)
        }
      ]

      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            // Performance Efficiency: scale out when concurrent HTTP requests exceed 10
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Fully-qualified domain name assigned by Azure (used to build HTTPS URLs).')
output fqdn string = app.properties.configuration.ingress.fqdn

@description('App name — used as the internal hostname within the Container Apps Environment.')
output appName string = app.name
