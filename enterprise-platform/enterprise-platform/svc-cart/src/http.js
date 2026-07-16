// Thin HTTP client for service-to-service calls.
// Retries, timeout, and dependency metrics - the things that make
// inter-service calls survivable in production.
const axios = require('axios');
const logger = require('./logger');
const { dependencyRequestsTotal } = require('./metrics');

const TIMEOUT_MS = parseInt(process.env.HTTP_TIMEOUT_MS || '3000', 10);
const RETRIES = parseInt(process.env.HTTP_RETRIES || '2', 10);

async function callService(name, baseUrl, path, options = {}) {
  const url = `${baseUrl}${path}`;
  let lastErr;

  for (let attempt = 0; attempt <= RETRIES; attempt++) {
    try {
      const res = await axios({
        url,
        method: options.method || 'GET',
        data: options.data,
        headers: {
          'x-request-id': options.requestId || '',
          ...options.headers,
        },
        timeout: TIMEOUT_MS,
      });
      dependencyRequestsTotal.inc({ dependency: name, status: 'success' });
      return res.data;
    } catch (err) {
      lastErr = err;
      const status = err.response ? err.response.status : 'network_error';
      logger.warn({ dependency: name, url, attempt, status }, 'dependency call failed');

      // Don't retry client errors - they won't get better.
      if (err.response && err.response.status >= 400 && err.response.status < 500) {
        dependencyRequestsTotal.inc({ dependency: name, status: 'client_error' });
        throw err;
      }

      // Exponential backoff with jitter
      if (attempt < RETRIES) {
        const backoff = Math.min(100 * Math.pow(2, attempt), 1000);
        const jitter = Math.random() * 100;
        await new Promise((r) => setTimeout(r, backoff + jitter));
      }
    }
  }

  dependencyRequestsTotal.inc({ dependency: name, status: 'failure' });
  throw lastErr;
}

module.exports = { callService };
