# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Provisions an Oracle Autonomous Database (ATP) on OCI with its MongoDB-compatible API enabled, so the [nestjs-dividend-portfolio](https://github.com/pigman8857/nestjs-dividend-portfolio) NestJS/Mongoose app can connect to it without code changes. Development environment only; uses OCI Always Free tier by default.

Remote repository: https://github.com/pigman8857/nestjs-dividend-portfolio-infra

## Common commands

```bash
terraform init                          # install providers (oracle/oci ~>6.0, random ~>3.6)
terraform plan                          # preview changes
terraform apply                         # provision (~3-5 min for ADB to become AVAILABLE)
terraform destroy                       # tear down all resources

terraform output mongodb_api_host       # hostname only
terraform output -raw mongo_uri_full    # full connection URI with password (sensitive)
terraform output manual_user_sql        # SQL to create the app user manually if provisioner failed
```

## Architecture

Single-file-per-concern layout — no modules:

- **`providers.tf`** — OCI provider auth (reads tenancy/user/fingerprint/key from tfvars)
- **`variables.tf`** — all inputs; the two sensitive ones are `adb_admin_password` and `adb_mongo_password`
- **`main.tf`** — `locals` block that assembles the MongoDB connection string and name prefix; no resources here
- **`database.tf`** — two resources:
  1. `oci_database_autonomous_database.adb` — the ATP instance
  2. `null_resource.create_mongo_user` — `local-exec` provisioner that downloads the wallet via OCI CLI and runs `sqlplus` to create the app DB user; gracefully no-ops if either tool is missing
- **`outputs.tf`** — connection host, full URI (sensitive), `.env` snippet, and the manual user-creation SQL as a fallback

## Key design decisions

**Why ATP / `db_workload = "OLTP"`** — only this workload type exposes the MongoDB-compatible API on port 27017.

**`is_mtls_connection_required = false`** — enables plain TLS mode. Without this, Mongoose would need an Oracle wallet (`.zip` with JKS trust store) which the driver does not natively support.

**`whitelisted_ips`** — the only network control in place (no VCN). Intentionally simple for local dev testing. Tighten `allowed_cidrs` to your IP before sharing the environment.

**MongoDB connection string parameters** — all four are mandatory for OCI ADB:
- `authMechanism=PLAIN` + `authSource=%24external` — Oracle uses PLAIN/LDAP auth, not MongoDB-native auth
- `retryWrites=false` — ADB MongoDB API does not support retryable writes
- `loadBalanced=true` — required for ADB's multi-node routing

## Required tfvars

`terraform.tfvars` is gitignored. Copy from `terraform.tfvars.example`. Mandatory fields that have no defaults:

```
tenancy_ocid, user_ocid, fingerprint, compartment_ocid
adb_admin_password, adb_mongo_password
```

`adb_name` must be alphanumeric, start with a letter, max 14 characters (no hyphens — it becomes part of the DNS hostname and the Oracle DB_NAME).

Password rules for both `*_password` vars: 12–30 chars, must include uppercase, lowercase, digit, and special character.

## Git workflow

`terraform.tfvars` and `.claude/` are gitignored — never stage them. When pushing, `gh auth setup-git` is required first if HTTPS credentials are not cached:

```bash
gh auth setup-git
git push
```

## Manual DB user fallback

If `null_resource.create_mongo_user` is skipped (no OCI CLI or `sqlplus`), run `terraform output manual_user_sql` and execute the result in **OCI Console → Autonomous Database → Database Actions → SQL** signed in as ADMIN. The user needs `CREATE SESSION`, `SODA_APP`, `CREATE TABLE/SEQUENCE/INDEX/VIEW`, and `QUOTA UNLIMITED ON DATA`.
