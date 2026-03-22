import { createServer } from 'node:http';
import { readFile, watch } from 'node:fs';
import { join, extname } from 'node:path';

const PORT = 3333;
const DIR = import.meta.dirname;

const MIME = {
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.glsl': 'text/plain',
  '.vert': 'text/plain',
  '.frag': 'text/plain',
  '.wgsl': 'text/plain',
};

// SSE clients waiting for reload signals
const clients = new Set();

// Watch all files in the directory
watch(DIR, { recursive: true }, (event, filename) => {
  if (!filename || filename === 'serve.js') return;
  const ext = extname(filename);
  const isShader = ['.glsl', '.vert', '.frag', '.wgsl'].includes(ext);

  const msg = JSON.stringify({ type: isShader ? 'shader' : 'reload', file: filename });
  for (const res of clients) {
    res.write(`data: ${msg}\n\n`);
  }
});

createServer((req, res) => {
  // SSE endpoint
  if (req.url === '/__reload') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'Access-Control-Allow-Origin': '*',
    });
    res.write(':ok\n\n');
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }

  // Static file serving — strip query string
  const raw = req.url.split('?')[0];
  const url = raw === '/' ? '/index.html' : raw;
  const filePath = join(DIR, url);
  const ext = extname(filePath);

  readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }
    res.writeHead(200, {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    res.end(data);
  });
}).listen(PORT, () => {
  console.log(`→ http://localhost:${PORT}`);
});
