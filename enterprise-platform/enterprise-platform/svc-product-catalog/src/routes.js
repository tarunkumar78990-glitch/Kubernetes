const express = require('express');
const router = express.Router();
const logger = require('./logger');

// In-memory store. A real deployment would put Cloud SQL / Firestore behind
// this; the shape of the service is what matters for the platform.
const PRODUCTS = [
  { id: 'p-1001', name: 'Aeron Chair',        price: 89000, currency: 'INR', stock: 12, category: 'furniture' },
  { id: 'p-1002', name: 'Mechanical Keyboard', price: 8900,  currency: 'INR', stock: 140, category: 'peripherals' },
  { id: 'p-1003', name: '4K Monitor 27"',     price: 32000, currency: 'INR', stock: 35, category: 'displays' },
  { id: 'p-1004', name: 'Noise Cancelling Headphones', price: 24000, currency: 'INR', stock: 78, category: 'audio' },
  { id: 'p-1005', name: 'Standing Desk',      price: 45000, currency: 'INR', stock: 8,  category: 'furniture' },
  { id: 'p-1006', name: 'Webcam 1080p',       price: 4500,  currency: 'INR', stock: 200, category: 'peripherals' },
];

router.get('/products', (req, res) => {
  const { category } = req.query;
  let result = PRODUCTS;
  if (category) {
    result = PRODUCTS.filter((p) => p.category === category);
  }
  res.json({ products: result, count: result.length });
});

router.get('/products/:id', (req, res) => {
  const product = PRODUCTS.find((p) => p.id === req.params.id);
  if (!product) {
    return res.status(404).json({ error: 'product_not_found', id: req.params.id });
  }
  res.json(product);
});

// Called by cart/order to confirm stock before committing.
router.post('/products/:id/reserve', (req, res) => {
  const qty = parseInt(req.body.quantity || '1', 10);
  const product = PRODUCTS.find((p) => p.id === req.params.id);

  if (!product) {
    return res.status(404).json({ error: 'product_not_found' });
  }
  if (product.stock < qty) {
    return res.status(409).json({ error: 'insufficient_stock', available: product.stock });
  }

  product.stock -= qty;
  logger.info({ productId: product.id, qty, remaining: product.stock }, 'stock reserved');
  res.json({ reserved: true, productId: product.id, quantity: qty, remaining: product.stock });
});

module.exports = router;
