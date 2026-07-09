const express = require('express');
const cors = require('cors');
const compression = require('compression');
const morgan = require('morgan');
const { createClient } = require('@supabase/supabase-js');

const START_TIME = Date.now();

function getSupabaseClient() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_ANON_KEY;
  if (!url || !key) {
    throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (or SUPABASE_ANON_KEY) must be set');
  }
  return createClient(url, key, { auth: { persistSession: false } });
}

/**
 * Creates a pre-wired Express app for a microservice: JSON parsing, CORS,
 * compression, request logging, a health endpoint for the load balancer,
 * and an X-Service-Instance response header identifying exactly which
 * replica served the request (used to verify load balancing works).
 */
function createService(name) {
  const app = express();
  const port = Number(process.env.PORT || 0);
  const instanceId = `${name}:${port}:${process.pid}`;

  app.use(cors());
  app.use(compression());
  app.use(express.json({ limit: '2mb' }));
  // NOTE: morgan parses any ":word" in the format string as a token
  // reference, so the service/port prefix must not contain a bare colon
  // followed by digits (e.g. "name:4011") — that gets misread as an
  // unknown ":4011" token and crashes the request. Use "|" as the separator.
  app.use(morgan(`[${name}|${port}] :method :url :status :response-time ms`));
  app.use((req, res, next) => {
    res.setHeader('X-Service-Instance', instanceId);
    next();
  });

  app.get('/health', (req, res) => {
    res.json({
      status: 'ok',
      service: name,
      port,
      pid: process.pid,
      uptimeSeconds: Math.round((Date.now() - START_TIME) / 1000),
    });
  });

  return { app, instanceId };
}

/**
 * Mounts real CRUD REST routes for a Supabase table under /<resource>.
 * Not a stub: every route performs an actual supabase-js call. Callers can
 * still add bespoke routes (business logic, computed endpoints) on the same
 * app before or after calling this.
 */
function mountCrud(app, { table, resource, idColumn = 'id', supabase, defaultOrder }) {
  const base = `/${resource}`;

  app.get(base, async (req, res) => {
    let q = supabase.from(table).select('*');
    if (defaultOrder) q = q.order(defaultOrder, { ascending: false });
    const limit = Math.min(Number(req.query.limit) || 100, 500);
    q = q.limit(limit);
    const { data, error } = await q;
    if (error) return res.status(500).json({ error: error.message });
    res.json({ data, count: data.length });
  });

  app.get(`${base}/:id`, async (req, res) => {
    const { data, error } = await supabase.from(table).select('*').eq(idColumn, req.params.id).maybeSingle();
    if (error) return res.status(500).json({ error: error.message });
    if (!data) return res.status(404).json({ error: `${resource} not found` });
    res.json({ data });
  });

  app.post(base, async (req, res) => {
    const { data, error } = await supabase.from(table).insert(req.body).select().single();
    if (error) return res.status(400).json({ error: error.message });
    res.status(201).json({ data });
  });

  app.patch(`${base}/:id`, async (req, res) => {
    const { data, error } = await supabase.from(table).update(req.body).eq(idColumn, req.params.id).select().maybeSingle();
    if (error) return res.status(400).json({ error: error.message });
    if (!data) return res.status(404).json({ error: `${resource} not found` });
    res.json({ data });
  });

  app.delete(`${base}/:id`, async (req, res) => {
    const { error } = await supabase.from(table).delete().eq(idColumn, req.params.id);
    if (error) return res.status(400).json({ error: error.message });
    res.status(204).end();
  });
}

function errorHandler(name) {
  return (err, req, res, next) => { // eslint-disable-line no-unused-vars
    console.error(`[${name}] unhandled error:`, err);
    res.status(500).json({ error: 'internal_error', message: err.message });
  };
}

function start(app, name) {
  const port = Number(process.env.PORT || 0);
  if (!port) throw new Error('PORT env var is required');
  app.use(errorHandler(name));
  app.listen(port, '127.0.0.1', () => {
    console.log(`[${name}] listening on 127.0.0.1:${port} (pid ${process.pid})`);
  });
}

module.exports = { createService, mountCrud, getSupabaseClient, start };
