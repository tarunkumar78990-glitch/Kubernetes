const express = require('express');
const router = express.Router();
const logger = require('./logger');
const { callService } = require('./http');

const CATALOG_URL = process.env.PRODUCT_CATALOG_URL || 'http://product-catalog:8080';

// userId -> [{productId, quantity, priceSnapshot}]
const carts = new Map();

router.get('/carts/:userId', (req, res) => {
  const items = carts.get(req.params.userId) || [];
  const total = items.reduce((sum, i) => sum + i.priceSnapshot * i.quantity, 0);
  res.json({ userId: req.params.userId, items, total, currency: 'INR' });
});

router.post('/carts/:userId/items', async (req, res, next) => {
  const { productId, quantity } = req.body;
  if (!productId || !quantity) {
    return res.status(400).json({ error: 'productId and quantity required' });
  }

  try {
    // Real inter-service call: validate the product exists and snapshot price.
    const product = await callService(
      'product-catalog',
      CATALOG_URL,
      `/api/products/${productId}`,
      { requestId: req.headers['x-request-id'] }
    );

    const items = carts.get(req.params.userId) || [];
    const existing = items.find((i) => i.productId === productId);

    if (existing) {
      existing.quantity += quantity;
    } else {
      items.push({
        productId,
        name: product.name,
        quantity,
        priceSnapshot: product.price,
      });
    }

    carts.set(req.params.userId, items);
    logger.info({ userId: req.params.userId, productId, quantity }, 'item added to cart');

    const total = items.reduce((sum, i) => sum + i.priceSnapshot * i.quantity, 0);
    res.status(201).json({ userId: req.params.userId, items, total });
  } catch (err) {
    if (err.response && err.response.status === 404) {
      return res.status(404).json({ error: 'product_not_found', productId });
    }
    next(err);
  }
});

router.delete('/carts/:userId/items/:productId', (req, res) => {
  const items = (carts.get(req.params.userId) || [])
    .filter((i) => i.productId !== req.params.productId);
  carts.set(req.params.userId, items);
  res.json({ userId: req.params.userId, items });
});

router.delete('/carts/:userId', (req, res) => {
  carts.delete(req.params.userId);
  res.status(204).send();
});

module.exports = router;
