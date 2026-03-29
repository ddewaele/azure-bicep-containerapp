'use strict'

const http = require('http')
const fs   = require('fs')
const path = require('path')
const os   = require('os')

const PORT        = parseInt(process.env.PORT        ?? '80',            10)
const BACKEND_URL = process.env.BACKEND_URL           ?? 'http://localhost:3000'
const HOSTNAME    = os.hostname()

// Read once at startup — the file never changes while the container is running
const html = fs.readFileSync(path.join(__dirname, 'index.html'))

// Parse the backend origin once so we're not doing it on every request
const backend = new URL(BACKEND_URL)

// ---------------------------------------------------------------------------
// Structured logger — writes JSON to stdout/stderr so Log Analytics can
// parse individual fields (level, method, path, status, durationMs, etc.).
// ---------------------------------------------------------------------------
function log(level, message, fields = {}) {
  const entry = {
    timestamp: new Date().toISOString(),
    level,
    service:  'frontend',
    hostname: HOSTNAME,
    message,
    ...fields,
  }
  const out = level === 'error' ? process.stderr : process.stdout
  out.write(JSON.stringify(entry) + '\n')
}

// ---------------------------------------------------------------------------
// Extract standard access-log fields from a request (similar to ALB/nginx logs)
// ---------------------------------------------------------------------------
function requestInfo(req) {
  return {
    remoteIp:      (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim(),
    remotePort:    req.socket.remotePort,
    method:        req.method,
    path:          req.url,
    httpVersion:   req.httpVersion,
    host:          req.headers.host || '-',
    userAgent:     req.headers['user-agent'] || '-',
    referer:       req.headers.referer || '-',
    contentLength: req.headers['content-length'] || 0,
    accept:        req.headers.accept || '-',
    forwarded:     req.headers['x-forwarded-for'] || '-',
    protocol:      req.headers['x-forwarded-proto'] || 'http',
  }
}

// ---------------------------------------------------------------------------
// Proxy: forward /api/* transparently to the internal backend container.
//
// The browser only ever talks to this frontend server (public HTTPS).
// The backend has no public endpoint, so this proxy is the only way to reach it.
// ---------------------------------------------------------------------------
function proxyToBackend(req, res) {
  const start = Date.now()

  const options = {
    hostname: backend.hostname,
    port:     parseInt(backend.port || '80', 10),
    path:     req.url,
    method:   req.method,
    headers:  { 'content-type': 'application/json' },
  }

  const upstream = http.request(options, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode, upstreamRes.headers)
    upstreamRes.pipe(res)

    log('info', 'Proxy request completed', {
      ...requestInfo(req),
      backendHost:   backend.hostname,
      backendStatus: upstreamRes.statusCode,
      durationMs:    Date.now() - start,
    })
  })

  upstream.on('error', (err) => {
    res.writeHead(502, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ error: 'Backend unavailable', detail: err.message }))

    log('error', 'Proxy request failed', {
      ...requestInfo(req),
      backendHost: backend.hostname,
      error:       err.message,
      durationMs:  Date.now() - start,
    })
  })

  req.pipe(upstream)
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------
const server = http.createServer((req, res) => {
  if (req.url.startsWith('/api/')) {
    proxyToBackend(req, res)
    return
  }

  // Serve the SPA for every other path
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
  res.end(html)

  log('info', 'Served SPA', {
    ...requestInfo(req),
    status: 200,
  })
})

server.listen(PORT, () => {
  log('info', 'Server started', { port: PORT, backendUrl: BACKEND_URL })
})
