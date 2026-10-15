const http = require('http');
const crypto = require('crypto');

const items = [
  { id: 1, sku: 'LAP-001', name: 'Laptop', stock: 42 },
  { id: 2, sku: 'MOU-002', name: 'Mouse', stock: 310 },
  { id: 3, sku: 'KEY-003', name: 'Keyboard', stock: 128 },
];

// CPU-heavy work: repeated SHA-256 hashing for `ms` milliseconds
function burn(ms) {
  const end = Date.now() + ms;
  let h = 'seed';
  while (Date.now() < end) h = crypto.createHash('sha256').update(h).digest('hex');
  return h;
}

const send = (res, code, body) => {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
};

http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  if (url === '/health') return send(res, 200, { status: 'ok' });
  if (url === '/items') return send(res, 200, items);
  const m = url.match(/^\/items\/(\d+)$/);
  if (m) {
    const it = items.find(i => i.id === Number(m[1]));
    return it ? send(res, 200, it) : send(res, 404, { error: 'not found' });
  }
  if (url === '/cpu') return send(res, 200, { hash: burn(100), host: process.env.HOSTNAME });
  send(res, 404, { error: 'not found' });
}).listen(3000, () => console.log('inventory-service listening on 3000'));
