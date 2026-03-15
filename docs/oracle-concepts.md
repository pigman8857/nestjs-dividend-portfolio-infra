# Oracle Concepts — Reference

Key Oracle/OCI-specific concepts that are relevant to this project and not obvious from a MongoDB/NestJS background.

---

## SODA (Simple Oracle Document Access)

Oracle's document store API that lets you interact with Oracle Database using a document/collection model similar to MongoDB — storing and querying JSON documents without writing SQL.

Oracle ADB's MongoDB-compatible API is built on top of SODA internally. When Mongoose creates a collection and inserts documents, the MongoDB wire protocol translates those operations into SODA calls under the hood.

The `SODA_APP` role grants the user permission to use this layer. Without it, the user can log in (`CREATE SESSION`) but cannot create collections or insert documents via the MongoDB API — it would fail with an authorization error on the first write operation.

---

## ORDS (Oracle REST Data Services)

The middleware layer that sits between the outside world and the Oracle database. It exposes the ADB as HTTP endpoints — including the `/ords/admin/_/sql` REST API used by the provisioner to run SQL, and the MongoDB wire protocol on port 27017.

ORDS starts after the ADB reaches `AVAILABLE` state but requires extra time to fully boot. This is why the provisioner polls the ORDS endpoint before attempting SQL.

**`ORDS.ENABLE_SCHEMA`** is a PL/SQL procedure that registers an Oracle user's schema with ORDS. It must be called after creating the user or the MongoDB wire protocol will reject all connections with:
```
Database connection unavailable. Ensure that the user exists and the schema
is enabled for use with Oracle REST Data Services.
```

---

## PL/SQL anonymous block terminator (`/`)

In Oracle's SQL execution environments (SQL*Plus, SQLcl, ORDS REST API), there are two types of statements:

- **DDL/DML** — single statements that end with `;` and execute immediately (`CREATE USER`, `GRANT`, etc.)
- **PL/SQL anonymous blocks** — multi-line procedural code wrapped in `BEGIN...END;`. The `;` after `END` closes the block syntax but does **not** trigger execution.

Oracle waits for a `/` on its own line as the signal to execute the buffered block. The reason `;` cannot trigger execution is that PL/SQL blocks contain many `;` inside them (one per statement) — Oracle cannot tell if the block is finished or still being written. `/` is unambiguous.

```sql
BEGIN
  ORDS.ENABLE_SCHEMA(...);
  COMMIT;
END;
/        ← executes the block above
```

Without `/`, ORDS buffers the block, returns HTTP 200 (the request was well-formed), but executes nothing — silently.

---

## ORDS REST API response behaviour

The `/ords/admin/_/sql` endpoint always returns **HTTP 200** regardless of whether the SQL inside succeeded or failed. Errors are reported in the response body JSON:

```json
{"items": [{"errorCode": 6550, "errorDetails": "ORA-06550: line 1, column 7..."}]}
```

This means checking the HTTP status code alone is insufficient to confirm SQL success. The response body must be inspected for `errorCode` (non-zero) or `ORA-XXXXX` patterns.

---

## Oracle username = MongoDB database name

Oracle ADB only permits a user to access their own schema via the MongoDB API. The MongoDB database name in the connection URI must match the authenticated Oracle username.

```
mongodb://mongoapp:<password>@<host>:27017/mongoapp?...
                                           ^^^^^^^^
                                           must equal the Oracle username
```

If the database name does not match, the MongoDB API returns:
```
MongoServerError: Operation listCollections on <DB_NAME> is not authorized.
```

---

## `CREATE INDEX` is not a grantable Oracle privilege

Unlike MongoDB where any user can create indexes freely, Oracle does not have a standalone `GRANT CREATE INDEX` privilege. The ability to create indexes on a user's own tables is implicit once `CREATE TABLE` is granted. Attempting to grant it explicitly raises:

```
ORA-00990: missing or invalid privilege
```

---

## `QUOTA UNLIMITED ON DATA`

Oracle users have **zero storage quota by default**. Even if a user has `CREATE TABLE` and all other privileges, any `INSERT` that causes data to be written to the `DATA` tablespace will fail silently or with a quota error unless storage quota is explicitly granted:

```sql
ALTER USER MONGOAPP QUOTA UNLIMITED ON DATA;
```

This is an Oracle-specific constraint with no MongoDB equivalent — in MongoDB any authenticated user can write data freely within their database.

---

## mTLS vs plain TLS (wallet)

Oracle ADB supports two TLS modes:

- **mTLS (mutual TLS)** — the default. Requires the client to present a certificate from an Oracle wallet (a `.zip` file containing a JKS trust store). Mongoose/MongoDB drivers do not natively support Oracle wallet files, so this mode requires extra setup.
- **Plain TLS** — enabled by setting `is_mtls_connection_required = false`. The client connects over standard TLS using the system's trusted CA chain, with no wallet needed. This is what Mongoose supports natively.

This project sets `is_mtls_connection_required = false` so the NestJS app can connect without downloading or configuring a wallet.

---

## `authMechanism=PLAIN` and `authSource=$external`

Oracle ADB authenticates MongoDB API users using LDAP-style PLAIN auth, not MongoDB's native SCRAM authentication. Two URI parameters are required to tell the driver this:

| Parameter | Value | Why |
|---|---|---|
| `authMechanism` | `PLAIN` | Use PLAIN (LDAP-style) instead of SCRAM |
| `authSource` | `$external` | Auth is handled externally (by Oracle), not by MongoDB's own user store |

Without these, the MongoDB driver defaults to SCRAM and the connection fails with an authentication error.

---

## `retryWrites=false`

MongoDB drivers retry certain write operations automatically on transient network errors by default. Oracle ADB's MongoDB-compatible API does not support this retryable writes protocol — it must be explicitly disabled in the URI:

```
retryWrites=false
```

Without this, the driver may attempt to use a retryable write path that ADB does not implement, resulting in errors on write operations.

---

## `loadBalanced=true`

Oracle ADB uses a multi-node architecture where connections are routed through a load balancer. The MongoDB driver must be told it is connecting to a load-balanced topology rather than a direct replica set:

```
loadBalanced=true
```

Without this, the driver attempts replica set discovery (e.g. `isMaster`/`hello` commands to find primary/secondary nodes), which ADB does not support in the MongoDB wire protocol. The connection either fails or behaves incorrectly.

---

## ATP vs ADW workload types

Oracle Autonomous Database comes in two workload types:

| Workload | Value | MongoDB API |
|---|---|---|
| Autonomous Transaction Processing | `OLTP` | ✅ Exposed on port 27017 |
| Autonomous Data Warehouse | `DW` | ❌ Not available |

Only `db_workload = "OLTP"` (ATP) exposes the MongoDB-compatible API. If `DW` is used, port 27017 is not opened and Mongoose cannot connect.

---

## Always Free `compute_count` drift

OCI automatically manages the `compute_count` of Always Free ADB instances. After provisioning, OCI may silently reduce it (e.g. from 2 to 1). On the next `terraform apply`, Terraform detects the drift and attempts to restore it, which OCI rejects with:

```
Error: 403-Forbidden — This feature is not supported in an Always Free
Autonomous AI Database.
```

The fix is to tell Terraform to ignore this attribute:

```hcl
lifecycle {
  ignore_changes = [compute_count]
}
```

This only applies to Always Free instances — paid instances allow `compute_count` to be managed by Terraform normally.
