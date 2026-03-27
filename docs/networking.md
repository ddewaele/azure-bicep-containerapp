# Networking deep-dive — how the frontend reaches the private backend

This document explains, layer by layer, why the backend is invisible to the internet and how the frontend is still able to talk to it.

## 1. The Container Apps Environment is a shared network boundary

When Bicep creates the `Microsoft.App/managedEnvironments` resource (in `modules/environment.bicep`), Azure provisions a private virtual network behind the scenes. Every Container App deployed into this environment shares that virtual network. Think of the environment as a walled garden — apps inside it can see each other, but the outside world can only see apps that explicitly open a door.

## 2. Ingress controls who can reach an app

Each Container App has an `ingress` block in its configuration. The key property is `external`:

```
                  ┌─────────────────────────────────────────────────┐
                  │       Container Apps Environment                 │
                  │          (shared virtual network)                │
  Internet        │                                                 │
     │            │   ┌───────────────────────────────────┐         │
     │  HTTPS     │   │  Frontend                         │         │
     ├───────────►│──►│  ingress.external: true            │         │
     │            │   │  → public FQDN, reachable from     │         │
     │            │   │    the internet over HTTPS          │         │
     │            │   └──────────┬────────────────────────┘         │
     │            │              │                                   │
     │            │              │  http://demo-...-backend          │
     │            │              │  (internal DNS, plain HTTP)       │
     │            │              ▼                                   │
     │            │   ┌───────────────────────────────────┐         │
     X  blocked   │   │  Backend                          │         │
     │            │   │  ingress.external: false            │         │
     │            │   │  → no public FQDN, unreachable     │         │
     │            │   │    from the internet                │         │
     │            │   └───────────────────────────────────┘         │
                  └─────────────────────────────────────────────────┘
```

The Bicep that controls this lives in `main.bicep`, where each app module receives `isExternalIngress`:

```bicep
// Backend — private
module backend 'modules/app.bicep' = if (deployApps) {
  params: {
    isExternalIngress: false   // ← no public endpoint
    targetPort:        3000
    ...
  }
}

// Frontend — public
module frontend 'modules/app.bicep' = if (deployApps) {
  params: {
    isExternalIngress: true    // ← reachable from the internet
    targetPort:        80
    ...
  }
}
```

Inside `modules/app.bicep`, this parameter maps directly to the Azure resource property:

```bicep
ingress: {
  external:      isExternalIngress   // true → public, false → internal only
  targetPort:    targetPort
  allowInsecure: false               // HTTP → HTTPS redirect enforced
}
```

When `external` is `false`, Azure simply **does not create a public IP or DNS entry** for that app. There is no firewall rule to misconfigure — the public endpoint doesn't exist.

## 3. Built-in DNS lets apps find each other by name

Azure automatically runs an internal DNS server inside every Container Apps Environment. When an app is created, Azure registers it under its **app name** as a hostname. No configuration needed — it happens automatically.

For example, if the backend Container App is named `demo-x7w5jyh2rldzi-backend`, then any other app in the same environment can reach it at:

```
http://demo-x7w5jyh2rldzi-backend
```

This is plain HTTP (not HTTPS) because the traffic never leaves the private virtual network — there's no need for TLS on an internal link.

## 4. The BACKEND_URL environment variable bridges Bicep and application code

The frontend needs to know the backend's internal hostname. Bicep handles this by reading the backend module's output and injecting it as an environment variable:

```bicep
// In main.bicep — the frontend module
module frontend 'modules/app.bicep' = if (deployApps) {
  params: {
    envVars: [
      {
        name:  'BACKEND_URL'
        value: 'http://${backend.outputs.appName}'  // e.g. http://demo-x7w5jyh2rldzi-backend
      }
    ]
    ...
  }
}
```

`backend.outputs.appName` is the actual Container App resource name — which is exactly what the internal DNS registers. This way, the frontend doesn't need any hardcoded hostnames.

## 5. The frontend server-side proxy forwards requests to the backend

The browser cannot call the backend directly — it has no public URL. Instead, the frontend's Node.js server acts as a **reverse proxy**. When the SPA makes a `fetch('/api/message')` call, here is what happens step by step:

```
 ① Browser sends:  GET https://<frontend-fqdn>/api/message
                         │
 ② Azure terminates TLS and forwards to the frontend container on port 80
                         │
                         ▼
 ③ frontend/server.js sees the path starts with /api/
    and does NOT serve index.html — instead it proxies:
                         │
                         ▼
 ④ frontend/server.js sends:  GET http://demo-x7w5jyh2rldzi-backend:3000/api/message
    (using the BACKEND_URL env var, over the private virtual network)
                         │
                         ▼
 ⑤ backend/server.js receives the request, returns JSON
                         │
                         ▼
 ⑥ frontend/server.js pipes the backend's response back to the browser
```

The relevant code in `frontend/server.js`:

```javascript
const BACKEND_URL = process.env.BACKEND_URL ?? 'http://localhost:3000'
const backend     = new URL(BACKEND_URL)

function proxyToBackend(req, res) {
  const options = {
    hostname: backend.hostname,    // e.g. demo-x7w5jyh2rldzi-backend
    port:     backend.port || 80,
    path:     req.url,             // e.g. /api/message
    method:   req.method,
  }

  const upstream = http.request(options, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode, upstreamRes.headers)
    upstreamRes.pipe(res)   // stream the backend response back to the browser
  })

  req.pipe(upstream)
}
```

## 6. Summary — what makes this secure

| Layer | What happens | Configured in |
|---|---|---|
| **Azure networking** | Backend has no public IP — only a private virtual network address | `ingress.external: false` in `modules/app.bicep` |
| **Internal DNS** | Apps resolve each other by name inside the environment | Automatic — managed by Azure |
| **Environment variable** | Frontend knows the backend's hostname without hardcoding it | `BACKEND_URL` env var wired in `main.bicep` |
| **Server-side proxy** | The frontend Node.js process makes the HTTP call to the backend; the browser never contacts the backend | `proxyToBackend()` in `frontend/server.js` |
| **HTTPS termination** | All external traffic is encrypted; Azure manages the TLS certificate | `allowInsecure: false` in `modules/app.bicep` |

The backend is never "hidden behind a firewall" — it simply **has no public endpoint to attack**. There is no IP address, no DNS record, and no port visible to the internet. The only path to it is through the frontend's server-side proxy running inside the same private network.
