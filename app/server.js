'use strict';
// PiBench dashboard — TinyServerLab
// Stateless Express app; all data lives in the dedicated PostgreSQL database.

const express = require('express');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');

const PORT = Number(process.env.PORT || 3000);
const INGEST_TOKEN = process.env.INGEST_TOKEN || '';
const BASE_PATH = (() => {
  let p = (process.env.BASE_PATH || '/pibench').trim();
  if (!p.startsWith('/')) p = '/' + p;
  return p.replace(/\/+$/, '');           // '' when hosted at /
})();

const pool = new Pool({
  host: process.env.DB_HOST || 'shared-postgres',
  port: Number(process.env.DB_PORT || 5432),
  database: process.env.DB_NAME || 'pibench_db',
  user: process.env.DB_USER || 'pibench_db_user',
  password: process.env.DB_PASSWORD,
  max: 5,
});

const SCHEMA = `
CREATE TABLE IF NOT EXISTS runs (
  id           SERIAL PRIMARY KEY,
  label        TEXT        NOT NULL,
  notes        TEXT,
  captured_at  TIMESTAMPTZ NOT NULL,
  system       JSONB       NOT NULL DEFAULT '{}'::jsonb,
  settings     JSONB       NOT NULL DEFAULT '{}'::jsonb,
  metrics      JSONB       NOT NULL DEFAULT '{}'::jsonb,
  samples      JSONB       NOT NULL DEFAULT '{}'::jsonb,
  version      TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS runs_captured_at_idx ON runs (captured_at);
`;

async function migrate() {
  for (let attempt = 1; ; attempt++) {
    try {
      await pool.query(SCHEMA);
      console.log('[pibench] schema ready');
      return;
    } catch (err) {
      if (attempt >= 30) throw err;
      console.log(`[pibench] waiting for database (${err.code || err.message}) ...`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

// ---------- helpers ----------
function requireToken(req, res, next) {
  if (!INGEST_TOKEN) return res.status(503).json({ error: 'INGEST_TOKEN is not configured on the server' });
  const got = (req.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const a = Buffer.from(got);
  const b = Buffer.from(INGEST_TOKEN);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return res.status(401).json({ error: 'invalid token' });
  next();
}

const LABEL_RE = /^[A-Za-z0-9._-]{1,64}$/;
function cleanNumberMap(obj, allowArrays) {
  const out = {};
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return out;
  for (const [k, v] of Object.entries(obj)) {
    if (typeof k !== 'string' || k.length > 300) continue;
    if (allowArrays) {
      if (Array.isArray(v)) out[k] = v.filter((x) => typeof x === 'number' && Number.isFinite(x)).slice(0, 100);
    } else if (v === null || (typeof v === 'number' && Number.isFinite(v))) {
      out[k] = v;
    }
  }
  return out;
}
const asObject = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});
const runColumns = 'id, label, notes, captured_at, system, settings, metrics, version, created_at';

// ---------- routes ----------
const router = express.Router();

router.get('/healthz', async (_req, res) => {
  try { await pool.query('SELECT 1'); res.json({ ok: true }); }
  catch { res.status(503).json({ ok: false }); }
});

router.get('/api/runs', async (_req, res, next) => {
  try {
    const { rows } = await pool.query(`SELECT ${runColumns} FROM runs ORDER BY captured_at, id`);
    res.json(rows);
  } catch (e) { next(e); }
});

router.get('/api/runs/:id(\\d+)', async (req, res, next) => {
  try {
    const { rows } = await pool.query(`SELECT ${runColumns}, samples FROM runs WHERE id = $1`, [req.params.id]);
    if (!rows.length) return res.status(404).json({ error: 'not found' });
    res.json(rows[0]);
  } catch (e) { next(e); }
});

router.post('/api/runs', requireToken, express.json({ limit: '2mb' }), async (req, res, next) => {
  try {
    const b = req.body || {};
    if (typeof b.label !== 'string' || !LABEL_RE.test(b.label)) return res.status(400).json({ error: 'label must match ' + LABEL_RE });
    const captured = new Date(b.captured_at || Date.now());
    if (Number.isNaN(captured.getTime())) return res.status(400).json({ error: 'invalid captured_at' });
    const metrics = cleanNumberMap(b.metrics, false);
    if (!Object.keys(metrics).length) return res.status(400).json({ error: 'metrics is empty' });
    const { rows } = await pool.query(
      `INSERT INTO runs (label, notes, captured_at, system, settings, metrics, samples, version)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`,
      [b.label, typeof b.notes === 'string' ? b.notes.slice(0, 2000) : null, captured,
       asObject(b.system), asObject(b.settings), metrics, cleanNumberMap(b.samples, true),
       typeof b.pibench_version === 'string' ? b.pibench_version.slice(0, 32) : null]
    );
    res.status(201).json({ id: rows[0].id });
  } catch (e) { next(e); }
});

router.patch('/api/runs/:id(\\d+)', requireToken, express.json(), async (req, res, next) => {
  try {
    const { label, notes } = req.body || {};
    if (label !== undefined && (typeof label !== 'string' || !LABEL_RE.test(label))) return res.status(400).json({ error: 'bad label' });
    const { rowCount } = await pool.query(
      `UPDATE runs SET label = COALESCE($2, label), notes = CASE WHEN $3::boolean THEN $4 ELSE notes END WHERE id = $1`,
      [req.params.id, label ?? null, notes !== undefined, typeof notes === 'string' ? notes.slice(0, 2000) : null]
    );
    if (!rowCount) return res.status(404).json({ error: 'not found' });
    res.json({ ok: true });
  } catch (e) { next(e); }
});

router.delete('/api/runs/:id(\\d+)', requireToken, async (req, res, next) => {
  try {
    const { rowCount } = await pool.query('DELETE FROM runs WHERE id = $1', [req.params.id]);
    if (!rowCount) return res.status(404).json({ error: 'not found' });
    res.json({ ok: true });
  } catch (e) { next(e); }
});

// index.html with <base href> so every relative URL works behind the path prefix
const PUBLIC_DIR = path.join(__dirname, 'public');
const indexHtml = fs.readFileSync(path.join(PUBLIC_DIR, 'index.html'), 'utf8')
  .replace('__BASE_HREF__', `${BASE_PATH}/`);
const sendIndex = (_req, res) => res.type('html').set('Cache-Control', 'no-cache').send(indexHtml);

router.get('/', sendIndex);
router.use(express.static(PUBLIC_DIR, { index: false, maxAge: '1h' }));

// ---------- app ----------
const app = express();
app.disable('x-powered-by');
app.set('trust proxy', true);

if (BASE_PATH) {
  // /pibench  ->  /pibench/   (so the browser treats it as a folder)
  app.get(BASE_PATH, (req, res, next) => {
    if (req.originalUrl.split('?')[0] === BASE_PATH) {
      const q = req.originalUrl.slice(BASE_PATH.length);
      return res.redirect(301, `${BASE_PATH}/${q}`);
    }
    next();
  });
  app.use(BASE_PATH, router);
}
// Also serve at / so it works if the proxy strips the prefix (Caddy handle_path)
app.use('/', router);

app.use((err, _req, res, _next) => {
  console.error('[pibench]', err);
  res.status(err.status || 500).json({ error: err.expose ? err.message : 'internal error' });
});

migrate()
  .then(() => app.listen(PORT, () => console.log(`[pibench] listening on :${PORT}, base path "${BASE_PATH || '/'}"`)))
  .catch((err) => { console.error('[pibench] startup failed:', err.message); process.exit(1); });

process.on('SIGTERM', () => pool.end().finally(() => process.exit(0)));
