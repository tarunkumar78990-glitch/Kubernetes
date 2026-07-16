const express = require('express');
const router = express.Router();
const { callService } = require('./http');

// Backend-for-frontend. Aggregates the services so the browser makes
// one call instead of five.
const CATALOG_URL        = process.env.PRODUCT_CATALOG_URL  || 'http://product-catalog:8080';
const CART_URL           = process.env.CART_URL             || 'http://cart:8080';
const ORDER_URL          = process.env.ORDER_URL            || 'http://order:8080';
const RECOMMENDATION_URL = process.env.RECOMMENDATION_URL   || 'http://recommendation:8080';
const CHECKOUT_URL       = process.env.CHECKOUT_URL         || 'http://checkout:8080';

router.get('/home', async (req, res, next) => {
  const requestId = req.headers['x-request-id'] || '';
  const userId = req.query.userId || 'anonymous';

  try {
    // Graceful degradation: the page still renders if recommendations
    // are down. Only the catalog is load-bearing.
    const [catalog, recommendations] = await Promise.all([
      callService('product-catalog', CATALOG_URL, '/api/products', { requestId }),
      callService('recommendation', RECOMMENDATION_URL,
        `/api/recommendations/${userId}`, { requestId })
        .catch(() => ({ recommendations: [], degraded: true })),
    ]);

    res.json({
      products: catalog.products,
      recommendations: recommendations.recommendations || [],
      degraded: !!recommendations.degraded,
    });
  } catch (err) {
    next(err);
  }
});

router.get('/dashboard/:userId', async (req, res, next) => {
  const requestId = req.headers['x-request-id'] || '';
  const { userId } = req.params;

  try {
    const [cart, orders] = await Promise.all([
      callService('cart', CART_URL, `/api/carts/${userId}`, { requestId })
        .catch(() => ({ items: [], total: 0, degraded: true })),
      callService('order', ORDER_URL, `/api/orders?userId=${userId}`, { requestId })
        .catch(() => ({ orders: [], degraded: true })),
    ]);

    res.json({ userId, cart, orders: orders.orders || [] });
  } catch (err) {
    next(err);
  }
});

// Proxy the checkout so the browser only ever talks to the frontend.
router.post('/checkout', async (req, res, next) => {
  try {
    const result = await callService('checkout', CHECKOUT_URL, '/api/checkout', {
      method: 'POST',
      data: req.body,
      requestId: req.headers['x-request-id'] || '',
    });
    res.status(201).json(result);
  } catch (err) {
    if (err.response) {
      return res.status(err.response.status).json(err.response.data);
    }
    next(err);
  }
});

module.exports = router;
