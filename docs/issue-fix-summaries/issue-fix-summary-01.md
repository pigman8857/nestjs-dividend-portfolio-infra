# Issue & Fix Summary — v1

**Date:** 2026-03-15
**Time:** 13:29 – 14:49 (UTC+7)

Recorded during initial integration testing of the NestJS/Mongoose app against OCI Autonomous Database (ATP) via the MongoDB-compatible API.

**Test result: PASS** — NestJS app starts successfully, connects to OCI ADB, and initialises all Mongoose collections including time series collections (`price_ticks`, `dividends`).

---

## Issue 1 — Hostname NXDOMAIN (DNS not resolving)

**Error**
```
MongoNetworkError: getaddrinfo ENOTFOUND dividenddev.adb.ap-singapore-1.oraclecloud.com
```

**Root cause**
`main.tf` constructed the MongoDB API hostname as `<adb_name>.adb.<region>.oraclecloud.com`. OCI actually assigns a tenancy-prefixed hostname on a different domain:
```
G384A9A0B4990AA-DIVIDENDDEV.adb.ap-singapore-1.oraclecloudapps.com
```

**Fix**
Read the actual hostname from `oci_database_autonomous_database.adb.connection_urls[0].mongo_db_url` (the URL OCI provides) and extract the host via regex, instead of constructing it from variables.

---

## Issue 2 — DB user never created (provisioner silently skipped)

**Error**
```
MongoServerError: Database connection unavailable. Ensure that the user exists
and the schema is enabled for use with Oracle REST Data Services.
```

**Root cause**
The `null_resource.create_mongo_user` provisioner used OCI CLI + sqlplus to create the DB user. Neither tool was installed. The script caught the missing `oci` command and exited with code `0` (success), so Terraform recorded the step as complete — but the user was never created.

**Fix**
Replaced the OCI CLI + sqlplus approach with a `curl` POST to the ADB's ORDS REST API endpoint (`/ords/admin/_/sql`). `curl` is pre-installed on virtually every Linux/macOS system, so no additional tools are required.

---

## Issue 3 — ORDS schema not enabled

**Error**
```
MongoServerError: Database connection unavailable. Ensure that the user exists
and the schema is enabled for use with Oracle REST Data Services.
A schema can be enabled by calling ORDS.ENABLE_SCHEMA.
```

**Root cause**
The original `manual_user_sql` output and provisioner SQL only created the user and granted privileges. `ORDS.ENABLE_SCHEMA` — required for the MongoDB wire protocol to accept connections — was missing.

**Fix**
Added a second `curl` call in the provisioner and a `BEGIN ORDS.ENABLE_SCHEMA(...) END;` block in `manual_user_sql` output. Both the automated path and the manual fallback now include this step.

---

## Issue 4 — `GRANT CREATE INDEX` is not a valid Oracle privilege

**Error**
```
ORA-00990: missing or invalid privilege
```

**Root cause**
`CREATE INDEX` is not a standalone grantable system privilege in Oracle. The ability to create indexes on owned tables is implicit with `CREATE TABLE`.

**Fix**
Removed `GRANT CREATE INDEX` from the provisioner SQL and `manual_user_sql` output.

---

## Issue 5 — `listCollections` not authorised (wrong MongoDB database name)

**Error**
```
MongoServerError: Operation listCollections on NESTJS_DIVIDEND_PORTFOLIO is not authorized.
```

**Root cause**
The MongoDB URI used `nestjs_dividend_portfolio` as the database name. Oracle ADB only allows a user to access their own Oracle schema via the MongoDB API. The database name in the URI must match the authenticated user's schema name (`mongoapp`).

**Fix**
- Updated `main.tf` to use `adb_mongo_username` as the database name in the URI (replacing `mongo_db_name` variable)
- Removed the now-unused `mongo_db_name` variable from `variables.tf`
- Updated `nestjs_env_snippet` output to emit `MONGO_DB_NAME=mongoapp`
- Updated NestJS `.env`: `MONGO_DB_NAME=mongoapp`

---

## Issue 6 — `compute_count` drift blocked `terraform apply`

**Error**
```
Error: 403-Forbidden, This feature is not supported in an Always Free
Autonomous AI Database. Upgrade this database to a paid database to use this feature.
```

**Root cause**
OCI auto-adjusted `compute_count` from 2 to 1 on the Always Free ADB after provisioning. Terraform detected the drift and tried to reset it to 2, which OCI rejected.

**Fix**
Added `lifecycle { ignore_changes = [compute_count] }` to the ADB resource in `database.tf`. OCI manages this value for Always Free instances.

---

## Summary table

| # | Error | Root cause | Fix |
|---|---|---|---|
| 1 | `ENOTFOUND` hostname | Wrong hostname format and domain | Read actual host from `connection_urls[0].mongo_db_url` |
| 2 | User does not exist | Provisioner silently skipped (no OCI CLI) | Replaced with `curl` + ORDS REST API |
| 3 | ORDS schema not enabled | `ORDS.ENABLE_SCHEMA` missing | Added to provisioner and manual SQL fallback |
| 4 | `ORA-00990` on GRANT | `CREATE INDEX` is not grantable in Oracle | Removed from grant list |
| 5 | `listCollections` not authorized | DB name in URI ≠ Oracle schema name | Use `adb_mongo_username` as the DB name |
| 6 | `terraform apply` 403 | `compute_count` drift on Always Free | `lifecycle { ignore_changes = [compute_count] }` |
