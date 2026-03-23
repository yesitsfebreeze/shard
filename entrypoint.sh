#!/bin/sh
cd /app/web && rm -rf node_modules/.cache && npm install --force
pm2 start /app/shard --name shard -- --mcp
pm2 start npx --name app -- vite --host 0.0.0.0 --port 3333
pm2 logs
