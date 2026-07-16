const express = require('express');
const router = express.Router();
const crypto = require('crypto');
const logger = require('./logger');
const { callService } = require('./http');

const CATALOG_URL = process.env.PRODUCT_CATALOG_URL || 'http://product-catalog:8080';

const orders = new Map();

router.post('/orders', async (req, res, next) => {
  const { userId, items, paymentId, shippingQuote } = req.body;

  if (!userId || !items || !items.length) {
    return res.status(400).json({ error: 'userId and items required' });
  }

  const orderId = `ord-${crypto.randomUUID().slice(0, 8)}`;

  try {
    // Reserve stock for every line item before we accept the order.
    for (const item of items) {
      await callService(
        'product-catalog',
        CATALOG_URL,
        `/api/products/${item.productId}/reserve`,
        {
          method: 'POST',
          data: { quantity: item.quantity },
          requestId: req.headers['x-request-id'],
        }
      );
    }

    const total = items.reduce((s, i) => s + i.priceSnapshot * i.quantity, 0);

    const order = {
      orderId,
      userId,
      items,
      paymentId,
      shipping: shippingQuote,
      subtotal: total,
      total: total + (shippingQuote ? shippingQuote.cost : 0),
      currency: 'INR',
      status: 'CONFIRMED',
      createdAt: new Date().toISOString(),
    };

    orders.set(orderId, order);
    logger.info({ orderId, userId, total: order.total }, 'order created');
    res.status(201).json(order);
  } catch (err) {
    if (err.response && err.response.status === 409) {
      return res.status(409).json({ error: 'insufficient_stock' });
    }
    next(err);
  }
});

router.get('/orders/:orderId', (req, res) => {
  const order = orders.get(req.params.orderId);
  if (!order) {
    return res.status(404).json({ error: 'order_not_found' });
  }
  res.json(order);
});

router.get('/orders', (req, res) => {
  const { userId } = req.query;
  let result = [...orders.values()];
  if (userId) {
    result = result.filter((o) => o.userId === userId);
  }
  res.json({ orders: result, count: result.length });
});

module.exports = router;
