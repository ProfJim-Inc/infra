# Node.js Service Patterns for Kubernetes

## Dockerfile Template (Express / Next.js / General Node)

### Express / General API Server
```dockerfile
# ---- Build Stage ----
FROM node:20-alpine AS builder

WORKDIR /app

# Copy dependency files first for layer caching
COPY package.json package-lock.json ./

# Use ci for reproducible installs
RUN npm ci --only=production && \
    cp -R node_modules /production_modules && \
    npm ci

# Copy source and build (if TypeScript or bundled)
COPY . .
RUN npm run build || true  # Skip if no build step

# ---- Runtime Stage ----
FROM node:20-alpine AS runtime

# Security: run as non-root (node user exists in official image)
RUN addgroup -g 1001 -S appgroup && \
    adduser -S appuser -u 1001 -G appgroup

WORKDIR /app

# Copy only production dependencies
COPY --from=builder /production_modules ./node_modules

# Copy built application
COPY --from=builder /app/dist ./dist
# Or if no build step:
# COPY --from=builder /app/src ./src
COPY --from=builder /app/package.json ./

# Set ownership
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1

# Use node directly (not npm start) so SIGTERM reaches the process
CMD ["node", "dist/index.js"]
```

### Next.js (Standalone)
```dockerfile
FROM node:20-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# Enable standalone output in next.config.js
RUN npm run build

# ---- Runtime ----
FROM node:20-alpine AS runtime

RUN addgroup -g 1001 -S appgroup && \
    adduser -S appuser -u 1001 -G appgroup

WORKDIR /app

# Next.js standalone output is self-contained
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

USER appuser

EXPOSE 3000

ENV HOSTNAME="0.0.0.0"
ENV PORT=3000

CMD ["node", "server.js"]
```

### Key notes:
- Always use `node` directly in CMD, not `npm start` — npm swallows SIGTERM and your app won't shut down gracefully
- Alpine images are ~5x smaller than Debian-based images
- `npm ci` is deterministic and faster than `npm install` in CI
- For Next.js, enable `output: 'standalone'` in `next.config.js` to get a self-contained server

## Health Check Patterns

### Express
```javascript
const express = require('express');
const app = express();

// Liveness — is the process alive?
app.get('/health', (req, res) => {
  res.json({ status: 'healthy' });
});

// Readiness — can we handle traffic?
app.get('/ready', async (req, res) => {
  const checks = {};

  try {
    // Check database
    await db.query('SELECT 1');
    checks.database = 'ok';
  } catch (err) {
    checks.database = `error: ${err.message}`;
    return res.status(503).json({ status: 'not ready', checks });
  }

  try {
    // Check Redis
    await redis.ping();
    checks.redis = 'ok';
  } catch (err) {
    checks.redis = `error: ${err.message}`;
    return res.status(503).json({ status: 'not ready', checks });
  }

  res.json({ status: 'ready', checks });
});
```

### Next.js API Route
```javascript
// pages/api/health.js (or app/api/health/route.js)
export default function handler(req, res) {
  res.status(200).json({ status: 'healthy' });
}
```

## Graceful Shutdown

This is critical in Node.js because the default behavior on SIGTERM is to exit immediately, dropping all in-flight requests.

```javascript
const server = app.listen(port, () => {
  console.log(`Server listening on port ${port}`);
});

// Track open connections for graceful drain
let connections = new Set();

server.on('connection', (conn) => {
  connections.add(conn);
  conn.on('close', () => connections.delete(conn));
});

function gracefulShutdown(signal) {
  console.log(`Received ${signal}. Starting graceful shutdown...`);

  // Stop accepting new connections
  server.close(async () => {
    console.log('HTTP server closed');

    // Close database connections
    try {
      await db.end();
      console.log('Database connections closed');
    } catch (err) {
      console.error('Error closing database:', err);
    }

    // Close Redis
    try {
      await redis.quit();
      console.log('Redis connection closed');
    } catch (err) {
      console.error('Error closing Redis:', err);
    }

    console.log('Graceful shutdown complete');
    process.exit(0);
  });

  // Force close connections that aren't finishing
  setTimeout(() => {
    console.log('Forcing remaining connections closed');
    connections.forEach((conn) => conn.destroy());
  }, 10000); // 10 second timeout for in-flight requests

  // Hard exit if graceful shutdown takes too long
  setTimeout(() => {
    console.error('Graceful shutdown timed out, forcing exit');
    process.exit(1);
  }, 25000); // Must be less than terminationGracePeriodSeconds
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));
```

In Kubernetes deployment:
```yaml
spec:
  terminationGracePeriodSeconds: 30
  containers:
    - name: app
      lifecycle:
        preStop:
          exec:
            command: ["sleep", "5"]  # let load balancer deregister first
```

## Structured Logging

```javascript
const pino = require('pino');

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  // JSON output by default — perfect for Kubernetes log aggregation
  formatters: {
    level: (label) => ({ level: label }),
  },
  timestamp: pino.stdTimeFunctions.isoTime,
});

// Express middleware for request logging
const pinoHttp = require('pino-http');
app.use(pinoHttp({
  logger,
  customProps: (req) => ({
    requestId: req.headers['x-request-id'] || crypto.randomUUID(),
  }),
  serializers: {
    req: (req) => ({
      method: req.method,
      url: req.url,
      headers: { 'user-agent': req.headers['user-agent'] }
    }),
    res: (res) => ({
      statusCode: res.statusCode
    })
  }
}));

// Usage
logger.info({ userId: '123', action: 'login' }, 'User logged in');
// Output: {"level":"info","time":"2026-02-26T10:30:00.000Z","userId":"123","action":"login","msg":"User logged in"}
```

## Prometheus Metrics (Optional)

```javascript
const promClient = require('prom-client');

// Collect default Node.js metrics (memory, CPU, event loop lag)
promClient.collectDefaultMetrics();

const httpRequestDuration = new promClient.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 5]
});

const httpRequestTotal = new promClient.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code']
});

// Middleware
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    const route = req.route?.path || req.path;
    httpRequestDuration.observe(
      { method: req.method, route, status_code: res.statusCode },
      duration
    );
    httpRequestTotal.inc(
      { method: req.method, route, status_code: res.statusCode }
    );
  });
  next();
});

// Metrics endpoint
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', promClient.register.contentType);
  res.end(await promClient.register.metrics());
});
```

## Environment Configuration Pattern

```javascript
// config.js — centralized configuration from environment variables
const config = {
  // App
  port: parseInt(process.env.PORT, 10) || 3000,
  nodeEnv: process.env.NODE_ENV || 'development',

  // Database
  databaseUrl: process.env.DATABASE_URL,  // Required
  dbPoolSize: parseInt(process.env.DB_POOL_SIZE, 10) || 10,

  // Redis
  redisUrl: process.env.REDIS_URL || 'redis://localhost:6379',

  // External APIs
  stripeApiKey: process.env.STRIPE_API_KEY,  // Injected via K8s Secret

  // Feature flags
  enableNewCheckout: process.env.ENABLE_NEW_CHECKOUT === 'true',
};

// Fail fast on missing required config
const required = ['databaseUrl'];
for (const key of required) {
  if (!config[key]) {
    console.error(`Missing required environment variable for ${key}`);
    process.exit(1);
  }
}

module.exports = config;
```

## .dockerignore

```
node_modules
npm-debug.log
.git
.gitignore
.env
.env.*
!.env.example
Dockerfile
docker-compose*.yml
.github
.vscode
*.md
tests/
__tests__/
coverage/
.next/cache
```
