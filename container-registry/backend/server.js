'use strict'

const http = require('http')
const os   = require('os')

const PORT     = parseInt(process.env.PORT ?? '3000', 10)
const HOSTNAME = os.hostname()

// ---------------------------------------------------------------------------
// Structured logger — writes JSON to stdout/stderr so Log Analytics can
// parse individual fields (level, method, path, status, durationMs, etc.).
// ---------------------------------------------------------------------------
function log(level, message, fields = {}) {
  const entry = {
    timestamp: new Date().toISOString(),
    level,
    service:  'backend',
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
// Request handlers — one entry per route
// ---------------------------------------------------------------------------
const routes = {
  'GET /api/message': (_req, res) => {
    const body = {
      message:   'Hello from the backend API!',
      hostname:  HOSTNAME,
      timestamp: new Date().toISOString(),
    }
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(body))
  },
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------
const server = http.createServer((req, res) => {
  const start   = Date.now()
  const handler = routes[`${req.method} ${req.url}`]

  const info = requestInfo(req)

  if (handler) {
    handler(req, res)
    log('info', 'Request handled', {
      ...info,
      status:     200,
      durationMs: Date.now() - start,
    })
  } else {
    res.writeHead(404, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ error: 'Not found', path: req.url }))
    log('warn', 'Route not found', {
      ...info,
      status:     404,
      durationMs: Date.now() - start,
    })
  }
})

server.listen(PORT, () => {
  log('info', 'Server started', { port: PORT })
})
