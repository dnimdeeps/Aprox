import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'
import { nodePolyfills } from 'vite-plugin-node-polyfills'

export default defineConfig({
  plugins: [react(), nodePolyfills()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
    dedupe: ['react', 'react-dom'],
  },
  optimizeDeps: {
    include: [
      'react',
      'react-dom',
      'react-dom/client',
      'react/jsx-runtime',
      '@tanstack/react-query',
      'viem',
      'viem/chains',
      'viem/account-abstraction',
      'framer-motion',
      'lucide-react',
      'sonner',
      'clsx',
      'tailwind-merge',
      'vite-plugin-node-polyfills/shims/buffer',
      'vite-plugin-node-polyfills/shims/global',
      'vite-plugin-node-polyfills/shims/process',
    ],
  },
  server: {
    host: '0.0.0.0',
    port: 5173,
    allowedHosts: true,
    cors: true,
    hmr: {
      clientPort: 443,
      protocol: 'wss',
    },
    proxy: {
      '/api': {
        target: 'http://localhost:3001',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
      '/ws/price': {
        target: 'ws://localhost:3001',
        ws: true,
        changeOrigin: true,
      },
      // Proxy Circle modular-sdk calls to avoid CORS — the browser origin is
      // this preview domain; Circle's CORS policy requires the request to come
      // from the same server-side origin, so we forward via Vite instead.
      '/circle-rpc': {
        target: 'https://modular-sdk.circle.com',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/circle-rpc/, '/v1/rpc/w3s/buidl'),
        secure: true,
      },
    },
  },
  preview: {
    host: '0.0.0.0',
    port: 5173,
    allowedHosts: true,
    proxy: {
      '/api': {
        target: 'http://localhost:3001',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
      '/ws/price': {
        target: 'ws://localhost:3001',
        ws: true,
        changeOrigin: true,
      },
      '/circle-rpc': {
        target: 'https://modular-sdk.circle.com',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/circle-rpc/, '/v1/rpc/w3s/buidl'),
        secure: true,
      },
    },
  },
})
