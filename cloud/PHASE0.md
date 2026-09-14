# Phase 0 — Cloud project setup (operator actions)

Goal: Supabase-SG database + Railway API host, ready for Phase 1 wiring.
Repo stays untouched by secrets: `.gitignore` covers `.env*` — never paste
connection strings into any repo file. Hand them over via chat only.

## Step 1 — Supabase (Singapore, Free)

1. supabase.com → New project, region **Singapore**, Free plan.
2. Project Settings → Database → copy the **session-mode** URI
   (pooler host, port **5432** — NOT the 6543 transaction pooler).
3. Ensure SSL: URI ends with `?sslmode=require`
   (use `&sslmode=require` if it already has `?…` params).
4. Save the database password shown at creation (shown once).

## Step 2 — Railway

1. railway.app → New Project → blank service (repo wiring lands in Phase 1).
2. Note the region shown on the service.
3. Generate the public domain (`https://<name>.up.railway.app`).

## Step 3 — Hand over (chat only, three strings)

```text
SUPABASE_SESSION_URL=postgresql://postgres.[ref]:[password]@aws-...pooler.supabase.com:5432/postgres?sslmode=require
RAILWAY_URL=https://<name>.up.railway.app
RAILWAY_REGION=<dashboard region>
```

These go into Railway env config + transient local shells for validation
only, then local copies are shredded. `VOUCHER_PSK` is reused as-is unless
rotation is requested in Phase 4.

## Phase 1 preview (build mode, after handoff)

- `requirements.txt` (`psycopg[binary]==3.3.5`, matches local venv) +
  `railway.json` (Nixpacks, `python cloud/api.py`, `/healthz` check).
  **DONE — both files exist at repo root, validated 2026-09-14.**
- **Layout:** the API lives at `cloud/api.py` (Railway/Supabase deploy
  unit). `backend/api.py` is a symlink to it, so the systemd unit
  (`ExecStart …/backend/api.py`), `backend/test_*.py` imports, and the
  running production service are all unaffected.   `backend/schema.sql`
  stays the single source for DDL
  (`test_pg.py` loads it verbatim); Supabase install uses that path.
- `psql <session-url> -f backend/schema.sql`, then
  `TEST_DATABASE_URL=<scratch> python3 backend/test_pg.py` must go green.
- Full endpoint curl matrix against `RAILWAY_URL`, then latency + cost
  snapshot. Cutover stays a separate approval.
