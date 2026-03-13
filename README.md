# mongoOracleInfra

Terraform project that provisions an **Oracle Autonomous Database (ADB/ATP)** on OCI and enables its **MongoDB-compatible API** — allowing the [nestjs-dividend-portfolio](https://github.com/pigman8857/nestjs-dividend-portfolio) app to connect via Mongoose without any code changes.

```
NestJS app (Mongoose)  ──→  port 27017  ──→  OCI Autonomous Database (ATP)
                                              └─ MongoDB-compatible API
```

> This is a **development** environment. It uses the OCI Always Free tier by default (2 ECPU, 20 GB).

---

## How it works

Oracle ATP exposes a MongoDB-compatible wire protocol on port `27017`. Two settings make it Mongoose-friendly:

| Setting | Value | Why |
|---|---|---|
| `db_workload` | `OLTP` | Selects ATP, the only workload that exposes the MongoDB API |
| `is_mtls_connection_required` | `false` | Allows plain TLS — no wallet download needed for Mongoose |

The public endpoint is automatically assigned at:
```
<adb_name>.adb.<region>.oraclecloud.com:27017
```

---

## Prerequisites

| Tool | Purpose |
|---|---|
| [Terraform >= 1.5](https://developer.hashicorp.com/terraform/install) | Infrastructure provisioning |
| [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) | Used by Terraform provisioner to download wallet and create DB user |
| [sqlplus](https://www.oracle.com/database/technologies/instant-client/downloads.html) | Runs the user-creation SQL (optional — can be done manually via OCI Console) |
| An OCI account | Free tier is sufficient |

### OCI API key setup

If you have not set up an OCI API key yet:

```bash
# Install OCI CLI, then:
oci setup config
# Follow the prompts — this creates ~/.oci/config and ~/.oci/oci_api_key.pem
```

You will need four values from `~/.oci/config` (or OCI Console → Profile → API Keys):

- `tenancy_ocid`
- `user_ocid`
- `fingerprint`
- `private_key_path`

---

## Quick start

### 1. Clone and configure

```bash
git clone <this-repo>
cd mongoOracleInfra

cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and fill in your values. At minimum:

```hcl
tenancy_ocid       = "ocid1.tenancy.oc1..aaaa..."
user_ocid          = "ocid1.user.oc1..aaaa..."
fingerprint        = "aa:bb:cc:dd:..."
private_key_path   = "~/.oci/oci_api_key.pem"
region             = "ap-singapore-1"
compartment_ocid   = "ocid1.compartment.oc1..aaaa..."

adb_admin_password = "AdminP@ss123!"   # min 12 chars, upper+lower+digit+special
adb_mongo_password = "MongoP@ss123!"
```

> **Tip:** Find your public IP with `curl -s https://checkip.amazonaws.com` and set
> `allowed_cidrs = ["<your-ip>/32"]` for better security.

### 2. Deploy

```bash
terraform init
terraform plan
terraform apply
```

The apply takes roughly **3-5 minutes** while OCI provisions the database.

### 3. Get the connection string

```bash
terraform output -raw mongo_uri_full
```

Example output:
```
mongodb://mongoapp:MongoP@ss123!@dividenddev.adb.ap-singapore-1.oraclecloud.com:27017/nestjs_dividend_portfolio?authMechanism=PLAIN&authSource=%24external&ssl=true&retryWrites=false&loadBalanced=true
```

### 4. Configure the NestJS app

In the `nestjs-dividend-portfolio` project, set these environment variables:

```bash
# .env
MONGO_URI=<paste output from step 3>
MONGO_DB_NAME=nestjs_dividend_portfolio
```

Or export them inline:

```bash
export MONGO_URI=$(cd /path/to/mongoOracleInfra && terraform output -raw mongo_uri_full)
export MONGO_DB_NAME=nestjs_dividend_portfolio
npm run start:dev
```

---

## DB user creation

Terraform automatically creates the `MONGOAPP` Oracle user after the ADB is available (via `null_resource` + `local-exec`). It requires OCI CLI and `sqlplus` on the machine running Terraform.

**If the automatic step was skipped** (no `sqlplus`), create the user manually:

1. Go to **OCI Console → Autonomous Database → your DB → Database Actions → SQL**
2. Sign in as `ADMIN`
3. Run:

```bash
# Print the SQL to copy-paste:
terraform output manual_user_sql
```

---

## Useful outputs

```bash
terraform output adb_id            # OCID of the ADB
terraform output adb_state         # Should be AVAILABLE
terraform output mongodb_api_host  # Hostname only
terraform output nestjs_env_snippet  # Full .env block (URI placeholder)
terraform output -raw mongo_uri_full # Full URI with password (sensitive)
terraform output manual_user_sql   # SQL to create the app user manually
```

---

## File structure

```
mongoOracleInfra/
├── providers.tf              # OCI provider (oracle/oci ~> 6.0)
├── variables.tf              # All input variables with descriptions
├── main.tf                   # Local values & connection string builder
├── database.tf               # ADB resource + app user provisioner
├── outputs.tf                # Connection info, .env snippet, manual SQL
├── terraform.tfvars.example  # Copy → terraform.tfvars and fill in
└── .gitignore                # Excludes *.tfvars, state, wallet files
```

---

## Connection string parameters explained

| Parameter | Value | Reason |
|---|---|---|
| `authMechanism` | `PLAIN` | Oracle ADB uses PLAIN (LDAP-style) auth for the MongoDB API |
| `authSource` | `$external` | Required when auth is delegated outside MongoDB's own user store |
| `ssl` | `true` | ADB enforces TLS on port 27017 even in non-mTLS mode |
| `retryWrites` | `false` | ADB's MongoDB API does not support retryable writes |
| `loadBalanced` | `true` | Required for Oracle ADB's multi-node connection routing |

---

## Known limitations (dev scope)

- **No VCN / private networking** — the ADB uses public access with an IP allowlist. This is intentional for easy local dev testing.
- **Always Free quota** — OCI allows up to 2 Always Free ADB instances per tenancy. If you hit the limit, set `is_free_tier = false` in `terraform.tfvars`.
- **Time series collections** — The app's `dividends` and `price_ticks` schemas use MongoDB time series collections (`autoCreate: false`). You may need to create these manually in SQL Worksheet if Mongoose cannot create them through the MongoDB API.
- **No retryable writes** — `retryWrites=false` is already set in the URI, but be aware that any write failures will not be automatically retried by the driver.

---

## Teardown

```bash
terraform destroy
```

This removes the ADB and all data. The OCI Always Free quota is restored after the instance is terminated.
