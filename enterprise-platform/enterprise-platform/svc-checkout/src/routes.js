const express = require('express');
const router = express.Router();
const logger = require('./logger');
const { callService } = require('./http');

// The orchestrator. This is where the fan-out lives and where most of
// your latency budget gets spent, so it's the service to watch.
const CART_URL         = process.env.CART_URL         || 'http://cart:8080';
const PAYMENT_URL      = process.env.PAYMENT_URL      || 'http://payment:8080';
const SHIPPING_URL     = process.env.SHIPPING_URL     || 'http://shipping:8080';
const ORDER_URL        = process.env.ORDER_URL        || 'http://order:8080';
const NOTIFICATION_URL = process.env.NOTIFICATION_URL || 'http://notification:8080';

router.post('/checkout', async (req, res, next) => {
  const { userId, address, paymentMethod } = req.body;
  const requestId = req.headers['x-request-id'] || '';

  if (!userId || !address || !paymentMethod) {
    return res.status(400).json({ error: 'userId, address and paymentMethod required' });
  }

  try {
    // 1. Fetch the cart
    const cart = await callService('cart', CART_URL, `/api/carts/${userId}`, { requestId });
    if (!cart.items || cart.items.length === 0) {
      return res.status(400).json({ error: 'cart_empty' });
    }

    // 2. Shipping quote and payment authorisation can run in parallel -
    //    they don't depend on each other. Sequential here would add ~200ms.
    const [shippingQuote, payment] = await Promise.all([
      callService('shipping', SHIPPING_URL, '/api/shipping/quote', {
        method: 'POST',
        data: { address, items: cart.items },
        requestId,
      }),
      callService('payment', PAYMENT_URL, '/api/payments/authorize', {
        method: 'POST',
        data: { userId, amount: cart.total, currency: 'INR', method: paymentMethod },
        requestId,
      }),
    ]);

    if (payment.status !== 'AUTHORIZED') {
      logger.warn({ userId, paymentStatus: payment.status }, 'payment declined');
      return res.status(402).json({ error: 'payment_declined', reason: payment.reason });
    }

    // 3. Create the order (reserves stock)
    const order = await callService('order', ORDER_URL, '/api/orders', {
      method: 'POST',
      data: {
        userId,
        items: cart.items,
        paymentId: payment.paymentId,
        shippingQuote,
      },
      requestId,
    });

    // 4. Capture the payment now the order is real
    await callService('payment', PAYMENT_URL, `/api/payments/${payment.paymentId}/capture`, {
      method: 'POST',
      data: { orderId: order.orderId },
      requestId,
    });

    // 5. Clear the cart
    await callService('cart', CART_URL, `/api/carts/${userId}`, {
      method: 'DELETE',
      requestId,
    });

    // 6. Notify - best effort. A failed email must NOT fail the checkout.
    //    This is a deliberate reliability decision: the order is already
    //    paid for and committed.
    try {
      await callService('notification', NOTIFICATION_URL, '/api/notifications/send', {
        method: 'POST',
        data: {
          userId,
          channel: 'email',
          template: 'order_confirmation',
          data: { orderId: order.orderId, total: order.total },
        },
        requestId,
      });
    } catch (notifyErr) {
      logger.error({ err: notifyErr, orderId: order.orderId },
        'notification failed - order still succeeded');
    }

    logger.info({ orderId: order.orderId, userId, total: order.total }, 'checkout complete');
    res.status(201).json({
      orderId: order.orderId,
      status: 'CONFIRMED',
      total: order.total,
      paymentId: payment.paymentId,
      shipping: shippingQuote,
    });
  } catch (err) {
    if (err.response && err.response.status === 409) {
      return res.status(409).json({ error: 'insufficient_stock' });
    }
    next(err);
  }
});

module.exports = router;
