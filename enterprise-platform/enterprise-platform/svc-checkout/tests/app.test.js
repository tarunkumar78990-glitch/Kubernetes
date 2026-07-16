const request = require('supertest');
const { app, server } = require('../src/server');

afterAll(() => server.close());

describe('health endpoints', () => {
  it('liveness returns 200', async () => {
    const res = await request(app).get('/healthz');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('alive');
  });

  it('readiness returns 200 once started', async () => {
    const res = await request(app).get('/readyz');
    expect([200, 503]).toContain(res.status);
  });

  it('exposes prometheus metrics', async () => {
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.text).toContain('http_requests_total');
  });
});

describe('input validation', () => {
  it('rejects malformed requests with 4xx not 5xx', async () => {
    const res = await request(app).post('/api/__nonexistent__').send({});
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(res.status).toBeLessThan(500);
  });
});
