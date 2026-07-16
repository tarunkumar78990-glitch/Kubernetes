// Health endpoints. Kubernetes semantics matter here:
//   /healthz (liveness)  - am I broken beyond repair? restart me.
//   /readyz  (readiness) - can I serve traffic RIGHT NOW? if not, pull me
//                          from the Service endpoints but DON'T restart me.
// Conflating the two causes restart storms during dependency outages.

const express = require('express');
const router = express.Router();

let ready = false;
let shuttingDown = false;

function setReady(v) { ready = v; }
function setShuttingDown(v) { shuttingDown = v; }

router.get('/healthz', (req, res) => {
  // Liveness must NOT check dependencies. If the catalog DB is down,
  // restarting this pod fixes nothing and makes the outage worse.
  res.status(200).json({ status: 'alive', service: 'cart' });
});

router.get('/readyz', (req, res) => {
  if (shuttingDown) {
    return res.status(503).json({ status: 'shutting_down' });
  }
  if (!ready) {
    return res.status(503).json({ status: 'not_ready' });
  }
  res.status(200).json({ status: 'ready', service: 'cart' });
});

module.exports = { router, setReady, setShuttingDown };
