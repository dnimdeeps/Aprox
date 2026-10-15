/**
 * Serves the production Vite build from dist/ on port 5173.
 * Proxies /ws/price WebSocket and /api/* HTTP calls to the operator server on port 3001.
 * Replaces the Vite dev server for testing the production build in Arc Studio preview.
 */
import { readFileSync, existsSync } from 'fs'
import { join } from 'path'

const PORT = 5173
const OPERATOR_URL = 'http://localhost:3001'
const DIST = join(import.meta.dir, 'dist')

const MIME: Record<string, string> = {
  html: 'text/html',
  js: 'application/javascript',
  css: 'text/css',
  svg: 'image/svg+xml',
  png: 'image/png',
  ico: 'image/x-icon',
  json: 'application/json',
  woff2: 'font/woff2',
  woff: 'font/woff',
}

function mime(path: string): string {
  const ext = path.split('.').pop() ?? ''
  return MIME[ext] ?? 'application/octet-stream'
}

const server = Bun.serve({
  port: PORT,
  hostname: '0.0.0.0',
  async fetch(req) {
    const url = new URL(req.url)

    // Proxy /api/* to operator server
    if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/price') || url.pathname === '/health') {
      const target = OPERATOR_URL + url.pathname + url.search
      try {
        const resp = await fetch(target, {
          method: req.method,
          headers: req.headers,
          body: req.method !== 'GET' && req.method !== 'HEAD' ? req.body : undefined,
        })
        return new Response(resp.body, {
          status: resp.status,
          headers: resp.headers,
        })
      } catch {
        return new Response('Operator server unreachable', { status: 502 })
      }
    }

    // Serve static files from dist/
    let filePath = join(DIST, url.pathname)

    // SPA fallback — serve index.html for non-asset routes
    if (!existsSync(filePath) || filePath.endsWith('/')) {
      filePath = join(DIST, 'index.html')
    }

    try {
      const content = readFileSync(filePath)
      return new Response(content, {
        headers: {
          'Content-Type': mime(filePath),
          'Cache-Control': filePath.includes('/assets/') ? 'public, max-age=31536000, immutable' : 'no-cache',
        },
      })
    } catch {
      // Final fallback to index.html for SPA routing
      try {
        const index = readFileSync(join(DIST, 'index.html'))
        return new Response(index, { headers: { 'Content-Type': 'text/html', 'Cache-Control': 'no-cache' } })
      } catch {
        return new Response('Not found', { status: 404 })
      }
    }
  },
  websocket: {
    open() {},
    message() {},
    close() {},
  },
})

// WebSocket upgrade — proxy /ws/price to operator server on port 3001
// Bun's HTTP server handles WS upgrades separately
console.log(`[serve-dist] Production build served on port ${PORT}`)
console.log(`[serve-dist] Dist: ${DIST}`)
console.log(`[serve-dist] Operator proxy: ${OPERATOR_URL}`)
