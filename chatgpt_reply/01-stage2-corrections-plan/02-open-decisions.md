# Open decisions — confirm or override before the build

## (a) PostgreSQL driver: `psycopg` v3

Build installs `pip install "psycopg[binary]"` and codes against the v3 API
(`row_factory=dict_row`, `conn.transaction()`).

* Override with: `psycopg2` (v2 API differences must then be handled), or name
  another driver.

## (b) Numeric caps + empty-token rule

* `remaining_seconds` ≤ 8640000, `upload/download_kbps` ≤ 1000000
  (digit-only, non-empty; session cap 1440 unchanged).
* Empty token → deny (strict; `auth_client` always carries a token).

Override with different caps, or tolerate empty tokens — with a reason, since
fail-closed is the standing rule.
