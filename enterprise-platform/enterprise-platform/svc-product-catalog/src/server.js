const express = require('express');
const pinoHttp = require('pino-http');
const logger = require('./logger');
const { register, metricsMiddleware } = require('./metrics');
const health = require('./health');
const routes = require('./routes');

const PORT = parseInt(process.env.PORT || '8080', 10);
const SERVICE_NAME = process.env.SERVICE_NAME || 'product-catalog';

const app = express();

app.use(express.json({ limit: '1mb' }));
app.use(pinoHttp({ logger }));
app.use(metricsMiddleware);

// Health first - never behind auth or heavy middleware.
app.use(health.router);

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.use('/api', routes);

app.use((err, req, res, next) => {
  logger.error({ err }, 'unhandled error');
  res.status(500).json({ error: 'internal_error' });
});

const server = app.listen(PORT, () => {
  logger.info({ port: PORT }, `${SERVICE_NAME} listening`);
  health.setReady(true);
});

// ---- Graceful shutdown ----
// Without this you drop in-flight requests on every deploy, and your
// error budget pays for it. The sleep gives kube-proxy/endpoints time to
// stop sending new traffic before we stop accepting it.
async function shutdown(signal) {
  logger.info({ signal }, 'shutdown initiated');
  health.setShuttingDown(true);

  await new Promise((r) => setTimeout(r, 5000));

  server.close(() => {
    logger.info('http server closed');
    process.exit(0);
  });

  setTimeout(() => {
    logger.error('forced shutdown after timeout');
    process.exit(1);
  }, 25000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = { app, server };
