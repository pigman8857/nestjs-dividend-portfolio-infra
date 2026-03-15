# Infrastructure Files

Explanation of each Terraform file in this project and how they connect.

---

## `providers.tf`

Declares the Terraform version requirement (`>= 1.5`) and two providers:

- **`oracle/oci ~> 6.0`** — the main OCI provider used to create the database
- **`hashicorp/random ~> 3.6`** — declared but available if random values are needed later

Configures the OCI provider with the five auth values that come from `terraform.tfvars` (tenancy, user, fingerprint, key path, region).

---

## `variables.tf`

Defines every input the project accepts, grouped into three sections:

| Section | Key variables |
|---|---|
| OCI Auth | `tenancy_ocid`, `user_ocid`, `fingerprint`, `private_key_path`, `region` |
| Project | `project_name`, `environment` (used as naming prefix) |
| Database | `adb_name`, `adb_admin_password`, `adb_mongo_username`, `adb_mongo_password`, `is_free_tier`, `adb_ecpu_count`, `adb_storage_gb` |
| Network | `allowed_cidrs` |

Only two variables have no defaults and are always required: `adb_admin_password` and `adb_mongo_password` (both marked `sensitive = true`).

> **Note:** There is no separate `mongo_db_name` variable. Oracle ADB requires the MongoDB database name in the connection URI to match the authenticated user's Oracle schema name (`adb_mongo_username`). The URI is built using the username for both the credential and the database path.

---

## `main.tf`

Contains **only `locals`** — no resources. Builds computed values used across the project:

- `name_prefix` — e.g. `dividend-portfolio-dev`, used in resource display names
- `common_tags` — freeform tags applied to the ADB
- `_mongo_db_url_template` — reads the MongoDB API URL template directly from `oci_database_autonomous_database.adb.connection_urls[0].mongo_db_url`
- `adb_mongo_host` — extracts the actual hostname from the OCI-assigned template URL using regex. OCI assigns a tenancy-prefixed hostname (e.g. `G384A9A0B4990AA-DIVIDENDDEV.adb.ap-singapore-1.oraclecloudapps.com`) that cannot be predicted from `adb_name` alone.
- `mongo_uri` / `mongo_uri_with_password` — built by substituting credentials into OCI's template URL. The database path uses `adb_mongo_username` (Oracle requires it to match the schema name).

---

## `database.tf`

The core file — two resources:

### `oci_database_autonomous_database.adb`

Creates the Oracle ATP instance. The critical settings:

| Setting | Value | Why |
|---|---|---|
| `db_workload` | `OLTP` | Selects ATP — the only workload type that exposes the MongoDB API |
| `is_mtls_connection_required` | `false` | Plain TLS mode, no wallet download needed for Mongoose |
| `whitelisted_ips` | `var.allowed_cidrs` | IP allowlist — the only network control (no VCN) |
| `is_free_tier` | `true` (default) | 2 ECPU, 20 GB at no cost |

A `lifecycle { ignore_changes = [compute_count] }` block prevents Terraform from trying to modify `compute_count` on Always Free databases (OCI manages this value and rejects changes with a 403).

### `null_resource.create_mongo_user`

Runs after the ADB is provisioned. A `local-exec` bash script that uses **`curl`** to POST SQL to the ADB's ORDS REST API endpoint (`/ords/admin/_/sql`) — no OCI CLI or sqlplus required.

The script:
1. Constructs the SQL URL from `connection_urls[0].ords_url` (read directly from the provisioned resource)
2. POSTs the `CREATE USER` + `GRANT` statements as ADMIN via HTTP Basic auth
3. POSTs a second request to call `ORDS.ENABLE_SCHEMA` — required for the MongoDB wire protocol to accept connections from this user
4. Gracefully exits with a warning (no hard failure) if `curl` is not installed

Granted privileges:
- `CREATE SESSION` — basic login
- `SODA_APP` — SODA/MongoDB API collections
- `CREATE TABLE` — schema DDL for Mongoose models
- `CREATE SEQUENCE` — auto-increment fields
- `CREATE VIEW` — views used by some Mongoose plugins

> `CREATE INDEX` is **not** a grantable Oracle privilege — index creation on owned tables is implicit with `CREATE TABLE`.

If the provisioner is skipped, use the manual fallback in `outputs.tf`.

---

## `outputs.tf`

Exposes connection details after `terraform apply`:

| Output | Notes |
|---|---|
| `adb_id`, `adb_state`, `adb_display_name` | Basic ADB info |
| `mongodb_api_host` | Hostname only (tenancy-prefixed, e.g. `G384A9A0B4990AA-DIVIDENDDEV.adb.ap-singapore-1.oraclecloudapps.com`) |
| `mongodb_api_port` | Always `27017` |
| `mongo_uri_template` | URI with `$MONGO_PASSWORD` placeholder (safe to print) |
| `mongo_uri_full` | Full URI with password — marked `sensitive`, use `terraform output -raw mongo_uri_full` |
| `nestjs_env_snippet` | Ready-to-paste `.env` block; `MONGO_DB_NAME` is set to `adb_mongo_username` |
| `manual_user_sql` | SQL to run in OCI Console if the provisioner was skipped — includes `ORDS.ENABLE_SCHEMA` |

---

## `terraform.tfvars.example`

A template to copy to `terraform.tfvars` (which is gitignored). Contains all variables with example values and inline comments explaining each one.

---

## How the files connect

```
terraform.tfvars
      │
      ▼
variables.tf  ──→  main.tf (locals / connection string built from resource output)
      │                    │
      ▼                    ▼
providers.tf       database.tf (ADB resource + curl/ORDS user provisioner)
                           │
                           ▼
                       outputs.tf  ──→  NestJS .env
```
