// SPDX-License-Identifier: MIT
// LOCAL TEST DOUBLE for the Taskmarket read endpoint used by scripts/e2e-local.sh. Binds to 127.0.0.1 only.
// GET /api/tasks/{id} -> Taskmarket-shaped JSON; POST /__set?status=<s> changes the status (local control only).
import { createServer } from 'node:http';

const port = Number(process.argv[2] ?? 8788);
const taskId = process.argv[3] ?? '0x9ab3d5e1ca795d87364e8b46ee7cc2c67244d66eaf0a0c2eb3784b74c8447654';
let status = process.argv[4] ?? 'completed';
const expiryTime = new Date(Date.now() + 86_400_000).toISOString(); // fixed for the life of the mock

createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (req.method === 'POST' && url.pathname === '/__set') {
    status = url.searchParams.get('status') ?? status;
    res.writeHead(204).end();
    return;
  }
  if (req.method === 'GET' && url.pathname === `/api/tasks/${taskId}`) {
    res.writeHead(200, { 'content-type': 'application/json', date: new Date().toUTCString() });
    res.end(JSON.stringify({ id: taskId, status, expiryTime, mode: 'bounty', note: 'local mock' }));
    return;
  }
  res.writeHead(404, { 'content-type': 'application/json', date: new Date().toUTCString() }).end('{"error":"not found"}');
}).listen(port, '127.0.0.1', () => console.log(`mock taskmarket on 127.0.0.1:${port} status=${status}`));
