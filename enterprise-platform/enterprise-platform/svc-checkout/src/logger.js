// Structured JSON logging. Cloud Logging parses these fields automatically.
const pino = require('pino');

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  formatters: {
    level(label) {
      // Cloud Logging expects "severity", not "level"
      return { severity: label.toUpperCase() };
    },
  },
  base: {
    service: process.env.SERVICE_NAME || 'unknown',
    env: process.env.APP_ENV || 'unknown',
    version: process.env.APP_VERSION || 'unknown',
  },
  timestamp: pino.stdTimeFunctions.isoTime,
});

module.exports = logger;
