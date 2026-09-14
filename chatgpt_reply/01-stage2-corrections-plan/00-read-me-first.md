# For ChatGPT — review this Stage 2 corrections plan (reply 01)

> You are reviewing a PLAN, not code. Nothing has been edited or deployed.
> Operative repo: `vascalmod/openNDS-docs` (local workdir `~/portal_eap`).
> Scope lock: Stage 1 frozen; correct ONLY `custombinauth.voucher.sh`,
> `backend/api.py`, `backend/schema.sql` (+ tests to prove them). No Stage 3.

## What to check

1. `01-corrections-plan.md` — the full plan: per-file changes, test design,
   proof artifacts, done criteria.
2. `02-open-decisions.md` — two defaults needing your confirm-or-override
   before the build starts.

## How to reply

* APPROVE, or APPROVE WITH CHANGES (list exact changes per file), or REJECT.
* Flag anything that touches Stage 1, opens a grant path outside BinAuth,
  splits CPD/Chrome logic, or weakens fail-closed.
