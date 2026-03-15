# Issue & Fix Summary — v2

**Date:** 2026-03-15
**Time:** 16:59 – 17:07 (UTC+7)

Recorded during second-round integration testing — a full `terraform destroy` + `apply` cycle to validate that the automated provisioner works end-to-end without requiring the operator to manually run SQL in OCI Console (Database Actions → SQL Worksheet) to create the `MONGOAPP` user and call `ORDS.ENABLE_SCHEMA`.

**Test result: PASS** — `terraform apply` fully provisions ADB, creates the DB user, and enables the ORDS schema automatically. NestJS connects and all 9 API tests pass including ACID transactions and time series operations.

---

## Issue 1 — ORDS.ENABLE_SCHEMA silently not executed (missing PL/SQL terminator)

**Error**
```
MongoServerError: Database connection unavailable. Ensure that the user exists
and the schema is enabled for use with Oracle REST Data Services.
A schema can be enabled by calling the PL/SQL procedure ORDS.ENABLE_SCHEMA.
```

**Root cause**
The provisioner sent the `ORDS.ENABLE_SCHEMA` PL/SQL block to the ORDS REST API without a `/` terminator:

```sql
BEGIN
  ORDS.ENABLE_SCHEMA(...);
  COMMIT;
END;
```

**Background — Oracle PL/SQL block termination**
In Oracle's SQL execution environments (SQL*Plus, SQLcl, ORDS REST API), there are two types of statements:

- **DDL/DML** — single statements that end with `;` and execute immediately (`CREATE USER`, `GRANT`, etc.)
- **PL/SQL anonymous blocks** — multi-line procedural code wrapped in `BEGIN...END;`. The `;` after `END` closes the block syntax but does **not** trigger execution. Oracle waits for a `/` on its own line as the unambiguous signal to execute the buffered block.

The reason `;` cannot trigger execution for PL/SQL blocks is that blocks contain many `;` inside them (one per statement). If `;` triggered execution, Oracle would not know whether the block was finished or still being written. `/` is unambiguous — it always means "execute whatever is buffered now".

Without `/`, ORDS received the block, buffered it, waited for the terminator, never got it, and returned HTTP 200 (the request was well-formed) — but executed nothing, silently.

The manual SQL that worked in OCI Console included the `/`. The provisioner did not.

**Fix — `database.tf`**
Added `/` on a new line after `END;` in the ORDS SQL string passed to curl:

```sql
BEGIN
  ORDS.ENABLE_SCHEMA(...);
  COMMIT;
END;
/
```

---

## Issue 2 — SQL failures invisible to Terraform (response body discarded)

**Symptom**
Terraform recorded `null_resource.create_mongo_user` as successfully created even when the SQL inside failed. No error was surfaced.

**Root cause**
The ORDS REST API (`/ords/admin/_/sql`) always returns **HTTP 200** regardless of whether the SQL succeeded or failed. Errors are reported in the **response body** as JSON:

```json
{"items": [{"errorCode": 6550, "errorDetails": "ORA-06550: ..."}]}
```

The old provisioner used `-o /dev/null` to discard the response body and checked only the HTTP status code. A failed SQL was indistinguishable from a successful one.

**Fix — `database.tf`**
Replaced the blind curl calls with a `run_sql` helper function that:
- Captures the response body into a variable
- Scans it for `"errorCode":[^0]` or `ORA-XXXXX` patterns
- If found: prints the ORDS error response and exits 1 → Terraform surfaces a real failure
- If clean: prints `OK` and continues

```bash
run_sql() {
  local desc="$1"
  local sql="$2"
  RESPONSE=$(curl -s -X POST "$SQL_URL" \
    -H "Content-Type: application/sql" \
    --user "ADMIN:$ADMIN_PASS" \
    --data-binary "$sql")
  if echo "$RESPONSE" | grep -qiE '"errorCode":[^0]|ORA-[0-9]'; then
    echo "ERROR: $desc failed. ORDS response:"
    echo "$RESPONSE"
    exit 1
  fi
}
```

---

## Issue 3 — Retry loop could fall through after exhausting retries

**Symptom**
Not observed in testing, but identified as a latent defect during code review.

**Root cause**
The ORDS readiness poll loop had a maximum of 20 retries (10 minutes), but after exhausting all retries it fell through and attempted to run SQL anyway — against an endpoint that had not confirmed readiness. This could result in silent SQL failures on a slow-starting ADB.

**Fix — `database.tf`**
Added an explicit exit after the loop if ORDS never returned HTTP 200:

```bash
if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: ORDS did not become ready after $MAX_RETRIES attempts. Aborting."
  exit 1
fi
```

---

## Summary table

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `ORDS.ENABLE_SCHEMA` not executed | Missing `/` PL/SQL block terminator | Added `/` after `END;` in provisioner SQL |
| 2 | SQL failures invisible to Terraform | ORDS returns HTTP 200 on SQL error; body was discarded | Capture response body, scan for `errorCode`/`ORA-` |
| 3 | Retry loop could fall through | No exit after exhausting ORDS readiness retries | Added `exit 1` if ORDS never returned 200 |
