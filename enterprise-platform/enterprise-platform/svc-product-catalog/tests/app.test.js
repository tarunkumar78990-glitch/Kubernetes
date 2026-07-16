const request = require('supertest');
const { app, server } = require('../src/server');

afterAll(() => server.close());

describe('health endpoints', () => {
  it('liveness returns 200', async () => {
    const res = await request(app).get('/healthz');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('alive');
  });

  it('exposes prometheus metrics', async () => {
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.text).toContain('http_requests_total');
  });
});

describe('products API', () => {
  it('lists all products', async () => {
    const res = await request(app).get('/api/products');
    expect(res.status).toBe(200);
    expect(res.body.products.length).toBeGreaterThan(0);
  });

  it('filters by category', async () => {
    const res = await request(app).get('/api/products?category=furniture');
    expect(res.status).toBe(200);
    res.body.products.forEach((p) => expect(p.category).toBe('furniture'));
  });

  it('returns a single product', async () => {
    const res = await request(app).get('/api/products/p-1001');
    expect(res.status).toBe(200);
    expect(res.body.id).toBe('p-1001');
  });

  it('404s on unknown product', async () => {
    const res = await request(app).get('/api/products/does-not-exist');
    expect(res.status).toBe(404);
  });

  it('reserves stock', async () => {
    const res = await request(app)
      .post('/api/products/p-1002/reserve')
      .send({ quantity: 2 });
    expect(res.status).toBe(200);
    expect(res.body.reserved).toBe(true);
  });

  it('rejects reservation beyond stock', async () => {
    const res = await request(app)
      .post('/api/products/p-1005/reserve')
      .send({ quantity: 99999 });
    expect(res.status).toBe(409);
  });
});
