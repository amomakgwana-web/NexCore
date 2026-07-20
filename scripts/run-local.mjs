#!/usr/bin/env node
// Local process orchestrator — starts every service replica as a plain OS
// process (no Docker) and the nginx gateway in front of them, for
// environments where a Docker daemon isn't available. For real deployment,
// use `docker compose up --build` instead (see docker-compose.yml).
import { spawn } from 'child_process';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'services/manifest.json'), 'utf8'));

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
if (!SUPABASE_URL || (!SUPABASE_SERVICE_ROLE_KEY && !SUPABASE_ANON_KEY)) {
  console.error('SUPABASE_URL and one of SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY must be set in the environment before running this script.');
  process.exit(1);
}
if (!SUPABASE_SERVICE_ROLE_KEY) {
  console.warn('SUPABASE_SERVICE_ROLE_KEY not set — falling back to SUPABASE_ANON_KEY. RLS will apply, so writes to protected tables will be rejected. Set the service-role key for real deployments.');
}

const children = [];
const pidFile = path.join(root, 'gateway/logs/run-local.pids.json');
fs.mkdirSync(path.join(root, 'gateway/logs'), { recursive: true });

async function waitHealthy(port, timeoutMs = 15000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`);
      if (res.ok) return true;
    } catch (e) { /* not up yet */ }
    await new Promise(r => setTimeout(r, 200));
  }
  return false;
}

async function main() {
  console.log(`Starting ${manifest.services.reduce((s, v) => s + v.replicas, 0)} service replicas across ${manifest.services.length} services...`);

  for (const svc of manifest.services) {
    for (let i = 0; i < svc.replicas; i++) {
      const port = svc.portBase + i;
      const logFile = fs.openSync(path.join(root, `gateway/logs/${svc.name}-${i + 1}.log`), 'a');
      const child = spawn('node', [path.join(root, 'services', svc.name, 'index.js')], {
        cwd: path.join(root, 'services', svc.name),
        env: { ...process.env, PORT: String(port), SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY, GATEWAY_URL: `http://127.0.0.1:${manifest.gatewayPort}` },
        stdio: ['ignore', logFile, logFile],
        detached: true,
      });
      children.push({ name: `${svc.name}-${i + 1}`, port, pid: child.pid });
      child.unref();
    }
  }

  console.log('Waiting for all replicas to report healthy...');
  let allHealthy = true;
  for (const c of children) {
    const ok = await waitHealthy(c.port);
    console.log(`  ${ok ? '✓' : '✗'} ${c.name} (port ${c.port}, pid ${c.pid})`);
    if (!ok) allHealthy = false;
  }
  if (!allHealthy) {
    console.error('Some replicas failed to become healthy — check gateway/logs/*.log');
  }

  // Start nginx bound to 127.0.0.1 using our generated config, in the foreground
  // process group but backgrounded here so this script can exit after startup.
  const nginxLog = fs.openSync(path.join(root, 'gateway/logs/nginx-stdout.log'), 'a');
  const nginx = spawn('nginx', ['-c', path.join(root, 'gateway/nginx.local.conf'), '-g', 'daemon off;'], {
    stdio: ['ignore', nginxLog, nginxLog],
    detached: true,
  });
  children.push({ name: 'nginx-gateway', port: manifest.gatewayPort, pid: nginx.pid });
  nginx.unref();

  const gatewayOk = await waitHealthy(manifest.gatewayPort);
  console.log(`  ${gatewayOk ? '✓' : '✗'} nginx-gateway (port ${manifest.gatewayPort}, pid ${nginx.pid})`);

  fs.writeFileSync(pidFile, JSON.stringify(children, null, 2));
  console.log(`\nAll processes recorded in ${pidFile}`);
  console.log(`Gateway: http://127.0.0.1:${manifest.gatewayPort}`);
  console.log('Stop everything with: node scripts/stop-local.mjs');
}

main();
