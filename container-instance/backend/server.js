'use strict'

const http = require('http')
const fs   = require('fs')
const os   = require('os')

const PORT       = parseInt(process.env.PORT       ?? '3000', 10)
const MOUNT_PATH = process.env.MOUNT_PATH           ?? '/mnt/data'
const HOSTNAME   = os.hostname()

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

  // Lists files in the mounted Azure File Share.
  // Returns an error if the mount path doesn't exist (e.g. running locally).
  'GET /api/files': (_req, res) => {
    try {
      const entries = fs.readdirSync(MOUNT_PATH, { withFileTypes: true })
      const files = entries.map(e => ({
        name:      e.name,
        type:      e.isDirectory() ? 'directory' : 'file',
      }))
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ mountPath: MOUNT_PATH, files }))
    } catch (err) {
      res.writeHead(500, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ error: err.message, mountPath: MOUNT_PATH }))
    }
  },

  // Returns the content of a single file from the mount.
  // Usage: GET /api/file?name=hello.txt
  'GET /api/file': (req, res) => {
    const url      = new URL(req.url, `http://localhost`)
    const filename = url.searchParams.get('name')
    if (!filename) {
      res.writeHead(400, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ error: 'Missing ?name= query parameter' }))
      return
    }
    const filePath = `${MOUNT_PATH}/${filename}`
    try {
      const content = fs.readFileSync(filePath, 'utf8')
      res.writeHead(200, { 'Content-Type': 'text/plain' })
      res.end(content)
    } catch (err) {
      res.writeHead(404, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ error: err.message, filePath }))
    }
  },
}

const server = http.createServer((req, res) => {
  const start = Date.now()

  // Strip query string for route matching
  const routeKey = `${req.method} ${req.url.split('?')[0]}`
  const handler  = routes[routeKey]

  if (handler) {
    handler(req, res)
    log('info', 'Request handled', {
      method:     req.method,
      path:       req.url,
      status:     200,
      durationMs: Date.now() - start,
    })
  } else {
    res.writeHead(404, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ error: 'Not found', path: req.url }))
    log('warn', 'Route not found', {
      method:     req.method,
      path:       req.url,
      status:     404,
      durationMs: Date.now() - start,
    })
  }
})

server.listen(PORT, () => {
  log('info', 'Server started', { port: PORT, mountPath: MOUNT_PATH })
})
