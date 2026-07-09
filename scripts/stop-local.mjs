#!/usr/bin/env node
// Stops every process started by run-local.mjs.
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const pidFile = path.join(root, 'gateway/logs/run-local.pids.json');

if (!fs.existsSync(pidFile)) {
  console.log('No run-local.pids.json found — nothing to stop.');
  process.exit(0);
}

const children = JSON.parse(fs.readFileSync(pidFile, 'utf8'));
for (const c of children) {
  try {
    process.kill(c.pid, 'SIGTERM');
    console.log(`stopped ${c.name} (pid ${c.pid})`);
  } catch (e) {
    console.log(`${c.name} (pid ${c.pid}) already gone`);
  }
}
fs.unlinkSync(pidFile);
console.log('Done.');
