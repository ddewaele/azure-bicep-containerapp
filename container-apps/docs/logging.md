# Logging

## What gets logged

Both the frontend and backend write **structured JSON** to stdout (info/warn) and stderr (errors). Every log entry contains a consistent set of fields:

```json
{
  "timestamp": "2026-03-27T14:23:01.456Z",
  "level":     "info",
  "service":   "backend",
  "hostname":  "demo-x7w5jyh2rldzi-backend--abc123-6f8d9c7b5-4xz2q",
  "message":   "Request handled",
  "method":    "GET",
  "path":      "/api/message",
  "status":    200,
  "durationMs": 2
}
```

| Field | Purpose |
|---|---|
| `timestamp` | ISO 8601 UTC timestamp |
| `level` | `info`, `warn`, or `error` |
| `service` | `frontend` or `backend` — useful for filtering when both apps log to the same Log Analytics workspace |
| `hostname` | Container replica hostname — shows which replica handled the request (useful when scaled out) |
| `message` | Human-readable description of the event |
| `method` / `path` | HTTP method and URL path |
| `status` / `backendStatus` | HTTP status code (frontend uses `backendStatus` for the upstream response) |
| `durationMs` | Request duration in milliseconds |
| `error` | Error message (only present on failures) |

### Events logged by each service

| Service | Event | Level | When |
|---|---|---|---|
| **Backend** | `Server started` | info | Container starts |
| **Backend** | `Request handled` | info | Successful API response |
| **Backend** | `Route not found` | warn | Request to an unknown path |
| **Frontend** | `Server started` | info | Container starts (includes `backendUrl`) |
| **Frontend** | `Served SPA` | info | `index.html` served to a browser |
| **Frontend** | `Proxy request completed` | info | Successful proxy to backend |
| **Frontend** | `Proxy request failed` | error | Backend unreachable (502) |

---

## How logging flows from container to Azure

```
  Container stdout/stderr
         │
         ▼
  Container Apps runtime  (captures all console output automatically)
         │
         ▼
  Log Analytics Workspace  (configured in modules/environment.bicep)
         │
         ├──► az containerapp logs   (CLI — live streaming)
         ├──► Azure Portal           (Log Analytics query editor)
         └──► az monitor log-analytics query   (CLI — KQL queries)
```

Azure Container Apps captures everything written to stdout and stderr and forwards it to the Log Analytics workspace configured in `modules/environment.bicep`. There is no logging agent to install and no SDK to import — writing to stdout is all that's needed.

---

## Viewing logs with the Azure CLI

### Stream live logs

Watch logs in real time as requests come in. Press `Ctrl+C` to stop.

```bash
# Frontend logs
az containerapp logs show \
  --resource-group rg-biceps-demo \
  --name <frontend-app-name> \
  --type console \
  --follow

# Backend logs
az containerapp logs show \
  --resource-group rg-biceps-demo \
  --name <backend-app-name> \
  --type console \
  --follow
```

### Query logs with KQL (Kusto Query Language)

Log Analytics stores container output in the `ContainerAppConsoleLogs_CL` table. You can query it using KQL.

**All logs from the last 30 minutes, newest first:**

```bash
az monitor log-analytics query \
  --workspace <log-analytics-workspace-id> \
  --analytics-query "
    ContainerAppConsoleLogs_CL
    | where TimeGenerated > ago(30m)
    | project TimeGenerated, ContainerAppName_s, Log_s
    | order by TimeGenerated desc
    | take 50
  " \
  --output table
```

**Parse the structured JSON and filter by service:**

Since our apps write JSON, you can use KQL's `parse_json()` to extract individual fields:

```bash
az monitor log-analytics query \
  --workspace <log-analytics-workspace-id> \
  --analytics-query "
    ContainerAppConsoleLogs_CL
    | where TimeGenerated > ago(1h)
    | extend parsed = parse_json(Log_s)
    | where parsed.service == 'backend'
    | project
        TimeGenerated,
        level    = tostring(parsed.level),
        message  = tostring(parsed.message),
        method   = tostring(parsed.method),
        path     = tostring(parsed.path),
        status   = toint(parsed.status),
        duration = toint(parsed.durationMs)
    | order by TimeGenerated desc
    | take 50
  " \
  --output table
```

**Find all errors across both services:**

```bash
az monitor log-analytics query \
  --workspace <log-analytics-workspace-id> \
  --analytics-query "
    ContainerAppConsoleLogs_CL
    | where TimeGenerated > ago(24h)
    | extend parsed = parse_json(Log_s)
    | where parsed.level == 'error'
    | project
        TimeGenerated,
        service = tostring(parsed.service),
        message = tostring(parsed.message),
        error   = tostring(parsed.error),
        path    = tostring(parsed.path)
    | order by TimeGenerated desc
  " \
  --output table
```

**Average response time per endpoint (last hour):**

```bash
az monitor log-analytics query \
  --workspace <log-analytics-workspace-id> \
  --analytics-query "
    ContainerAppConsoleLogs_CL
    | where TimeGenerated > ago(1h)
    | extend parsed = parse_json(Log_s)
    | where isnotnull(parsed.durationMs)
    | summarize
        avgDuration = avg(toint(parsed.durationMs)),
        p95Duration = percentile(toint(parsed.durationMs), 95),
        count       = count()
      by
        service = tostring(parsed.service),
        path    = tostring(parsed.path)
  " \
  --output table
```

### Find your Log Analytics workspace ID

The workspace ID is needed for `az monitor log-analytics query`. To find it:

```bash
az monitor log-analytics workspace list \
  --resource-group rg-biceps-demo \
  --query "[].{name:name, id:customerId}" \
  --output table
```

---

## Viewing logs in the Azure Portal

1. Go to the [Azure Portal](https://portal.azure.com)
2. Navigate to your resource group (`rg-biceps-demo`)
3. Click on either Container App (frontend or backend)
4. In the left sidebar, under **Monitoring**, click **Log stream** for live output
5. Or click **Logs** to open the Log Analytics query editor where you can run the KQL queries above

---

## Viewing logs locally with Docker Compose

When running locally via `docker compose up`, logs are printed directly to your terminal. Use `docker compose logs` to filter:

```bash
# All logs
docker compose logs

# Only backend logs
docker compose logs backend

# Follow mode (live stream)
docker compose logs -f

# Follow only the frontend
docker compose logs -f frontend
```
