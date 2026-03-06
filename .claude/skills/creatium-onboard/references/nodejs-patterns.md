# Node.js Patterns for the Creatium Stack

---

## Dockerfile (Express / Fastify / Next.js)

### Express / Fastify API

```dockerfile
# ---- Dependencies Stage ----
FROM node:20-alpine AS deps

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --only=production

# ---- Build Stage (for TypeScript) ----
FROM node:20-alpine AS builder

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---- Runtime Stage ----
FROM node:20-alpine AS runtime

# Security: non-root
RUN addgroup -g 1001 -S nodejs && adduser -S appuser -u 1001 -G nodejs

WORKDIR /app

COPY --from=deps    /app/node_modules ./node_modules
COPY --from=builder /app/dist         ./dist
COPY --from=builder /app/package.json ./

RUN chown -R appuser:nodejs /app
USER appuser

EXPOSE 3000

CMD ["node", "dist/server.js"]
```

### Next.js (standalone output)

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
ENV NEXT_TELEMETRY_DISABLED 1
RUN npm run build

FROM node:20-alpine AS runtime
RUN addgroup -g 1001 -S nodejs && adduser -S nextjs -u 1001 -G nodejs
WORKDIR /app

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000
ENV NEXT_TELEMETRY_DISABLED 1
CMD ["node", "server.js"]
```

Requires `next.config.js`:
```js
module.exports = { output: 'standalone' }
```

`.dockerignore`:
```
.git
.github
node_modules
.next
.env
.env.*
!.env.example
.DS_Store
```

---

## Health Endpoints

### Express

```js
// routes/health.js
const router = require('express').Router()

router.get('/health', (req, res) => {
  res.json({ status: 'ok' })
})

router.get('/readiness', async (req, res) => {
  const checks = {}
  try {
    await db.query('SELECT 1')  // or pool.query()
    checks.database = 'ok'
  } catch (err) {
    checks.database = `error: ${err.message}`
    return res.status(503).json({ status: 'not ready', checks })
  }
  res.json({ status: 'ready', checks })
})

module.exports = router
```

### Fastify

```js
fastify.get('/health', async () => ({ status: 'ok' }))

fastify.get('/readiness', async (request, reply) => {
  try {
    await fastify.pg.query('SELECT 1')
    return { status: 'ready' }
  } catch (err) {
    reply.status(503)
    return { status: 'not ready', error: err.message }
  }
})
```

---

## Structured JSON Logging with OTeL Trace Injection

Use `pino` — it's the standard JSON logger for Node.js and is fast.

```bash
npm install pino pino-pretty @opentelemetry/api
```

```js
// lib/logger.js
const pino = require('pino')
const { trace } = require('@opentelemetry/api')

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  formatters: {
    log(obj) {
      // Inject OTeL trace/span IDs into every log line
      const span = trace.getActiveSpan()
      if (span) {
        const ctx = span.spanContext()
        if (ctx.traceId && ctx.spanId) {
          obj.trace_id = ctx.traceId
          obj.span_id = ctx.spanId
        }
      }
      return obj
    },
  },
  // Grafana expects these field names
  timestamp: pino.stdTimeFunctions.isoTime,
  messageKey: 'message',
  base: {
    service: process.env.SERVICE_NAME || 'my-service',
  },
})

module.exports = logger
```

Usage:
```js
const logger = require('./lib/logger')

logger.info({ item_id: 42, category: 'hardware' }, 'item created')
// → {"level":"info","time":"2024-01-15T12:34:56.000Z","service":"my-service",
//    "trace_id":"abc...","span_id":"def...","item_id":42,"category":"hardware",
//    "message":"item created"}
```

**Do not use `console.log`** — it goes to stdout but without structure.

---

## OTeL Distributed Tracing Setup

```bash
npm install @opentelemetry/sdk-node \
            @opentelemetry/auto-instrumentations-node \
            @opentelemetry/exporter-trace-otlp-grpc \
            @opentelemetry/resources \
            @opentelemetry/semantic-conventions
```

```js
// tracing.js — must be required BEFORE any other imports
const { NodeSDK } = require('@opentelemetry/sdk-node')
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc')
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node')
const { Resource } = require('@opentelemetry/resources')
const { SEMRESATTRS_SERVICE_NAME, SEMRESATTRS_SERVICE_VERSION } = require('@opentelemetry/semantic-conventions')
const { ConsoleSpanExporter } = require('@opentelemetry/sdk-trace-node')

const otlpEndpoint = process.env.OTLP_ENDPOINT ||
  'http://otel-collector.monitoring.svc.cluster.local:4317'

const exporter = otlpEndpoint
  ? new OTLPTraceExporter({ url: otlpEndpoint })
  : new ConsoleSpanExporter()  // local dev fallback

const sdk = new NodeSDK({
  resource: new Resource({
    [SEMRESATTRS_SERVICE_NAME]: process.env.SERVICE_NAME || 'my-service',
    [SEMRESATTRS_SERVICE_VERSION]: process.env.SERVICE_VERSION || '0.1.0',
    'deployment.environment': process.env.ENV || 'production',
  }),
  traceExporter: exporter,
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-http': { enabled: true },
      '@opentelemetry/instrumentation-express': { enabled: true },
    }),
  ],
})

sdk.start()
console.log(`OTeL tracing started → ${otlpEndpoint || 'console (dev mode)'}`)

process.on('SIGTERM', () => sdk.shutdown().then(() => process.exit(0)))
```

In `package.json`:
```json
{
  "scripts": {
    "start": "node -r ./tracing.js dist/server.js"
  }
}
```

Or in the Dockerfile `CMD`:
```dockerfile
CMD ["node", "-r", "./tracing.js", "dist/server.js"]
```

Environment variables (set in `values.yaml` under `config:`):
- `OTLP_ENDPOINT`: `http://otel-collector.monitoring.svc.cluster.local:4317`
- `SERVICE_NAME`: `<your-service-name>`
- `SERVICE_VERSION`: `1.0.0`
- `ENV`: `production`

---

## Prometheus Metrics

```bash
npm install prom-client
```

```js
// lib/metrics.js
const client = require('prom-client')

// Collect default Node.js metrics (event loop, heap, GC, etc.)
client.collectDefaultMetrics({ prefix: 'nodejs_' })

// Custom metrics example
const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
})

module.exports = { client, httpRequestDuration }

// In your Express app:
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer()
  res.on('finish', () => {
    end({ method: req.method, route: req.route?.path || req.path, status_code: res.statusCode })
  })
  next()
})

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', client.register.contentType)
  res.end(await client.register.metrics())
})
```

---

## Graceful Shutdown (Express)

```js
const server = app.listen(3000, () => {
  logger.info({ port: 3000 }, 'server started')
})

process.on('SIGTERM', () => {
  logger.info('SIGTERM received, shutting down gracefully')
  server.close(() => {
    // Close database connections, flush message queues, etc.
    db.end()
    logger.info('shutdown complete')
    process.exit(0)
  })

  // Force kill if not done within 15 seconds
  setTimeout(() => {
    logger.error('shutdown timeout, forcing exit')
    process.exit(1)
  }, 15_000)
})
```

---

## Environment Configuration

```js
// config.js — single source of truth for all config
module.exports = {
  port: parseInt(process.env.PORT || '3000'),
  logLevel: process.env.LOG_LEVEL || 'info',
  serviceName: process.env.SERVICE_NAME || 'my-service',
  serviceVersion: process.env.SERVICE_VERSION || '0.1.0',
  env: process.env.ENV || 'production',
  otlpEndpoint: process.env.OTLP_ENDPOINT || 'http://otel-collector.monitoring.svc.cluster.local:4317',

  // Required secrets — fail fast at startup if not set
  databaseUrl: required('DATABASE_URL'),
  redisUrl: process.env.REDIS_URL || 'redis://redis.internal:6379',
  stripeApiKey: process.env.STRIPE_API_KEY || '',
}

function required(name) {
  const value = process.env[name]
  if (!value) throw new Error(`Required environment variable ${name} is not set`)
  return value
}
```
