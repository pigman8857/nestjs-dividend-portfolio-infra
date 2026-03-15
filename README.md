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

The public endpoint is assigned by OCI at provisioning time in the format:
```
<TENANCY_PREFIX>-<ADB_NAME>.adb.<region>.oraclecloudapps.com:27017
```

> The hostname includes a tenancy-specific prefix and uses `.oraclecloudapps.com` — it is read directly from the provisioned resource, not constructed from variables.

---

## Prerequisites

| Tool | Purpose |
|---|---|
| [Terraform >= 1.5](https://developer.hashicorp.com/terraform/install) | Infrastructure provisioning |
| `curl` | Used by the provisioner to create the DB user via ORDS REST API — pre-installed on most systems |
| An OCI account | Free tier is sufficient |

> OCI CLI and sqlplus are **not required**. The DB user is created automatically via the ORDS REST API using `curl`.

### OCI API key setup

If you have not set up an OCI API key yet, go to **OCI Console → My profile → API keys → Add API key**:

1. Generate an API key pair and download the private key (`.pem`)
2. Save it to `~/.oci/oci_api_key.pem` and run `chmod 600 ~/.oci/oci_api_key.pem`
3. Note the fingerprint shown (format: `aa:bb:cc:dd:...`)

You will need four values from OCI Console → Profile → API Keys:

- `tenancy_ocid`
- `user_ocid`
- `fingerprint`
- `private_key_path`

---

## Quick start

### 1. Clone and configure

```bash
git clone https://github.com/pigman8857/nestjs-dividend-portfolio-infra
cd nestjs-dividend-portfolio-infra

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

adb_admin_password = "YourAdminPassword1"   # min 12 chars, upper+lower+digit+special
adb_mongo_password = "YourMongoPassword1"
```

> **Tip:** Find your public IP with `curl -s https://checkip.amazonaws.com` and set
> `allowed_cidrs = ["<your-ip>/32"]` for better security.

### 2. Deploy

```bash
terraform init
terraform plan
terraform apply
```

The apply takes roughly **3-5 minutes** while OCI provisions the database. On completion, Terraform automatically:
- Creates the `MONGOAPP` Oracle user with all required grants
- Enables the ORDS schema for MongoDB wire protocol access

### 3. Get the connection string

```bash
terraform output -raw mongo_uri_full
```

Example output:
```
mongodb://mongoapp:YourMongoPassword1@G384A9A0B4990AA-DIVIDENDDEV.adb.ap-singapore-1.oraclecloudapps.com:27017/mongoapp?authMechanism=PLAIN&authSource=$external&ssl=true&retryWrites=false&loadBalanced=true
```

### 4. Configure the NestJS app

```bash
# .env
MONGO_URI=<paste output from step 3>
MONGO_DB_NAME=mongoapp
```

> **Important:** `MONGO_DB_NAME` must be `mongoapp` (the Oracle username) — Oracle ADB only allows a user to access their own schema via the MongoDB API.

Or export inline:

```bash
export MONGO_URI=$(cd /path/to/mongoOracleInfra && terraform output -raw mongo_uri_full)
export MONGO_DB_NAME=mongoapp
npm run start:dev
```

---

## DB user creation

Terraform automatically creates the `MONGOAPP` Oracle user after the ADB is available via a `curl` POST to the ORDS REST API — no OCI CLI or sqlplus needed.

**If the automatic step was skipped** (curl unavailable or ORDS not ready), create the user manually:

1. Run `terraform output manual_user_sql` and copy the output
2. Go to **OCI Console → Autonomous Database → your DB → Database Actions → SQL**
3. Sign in as `ADMIN` and run the **entire SQL block in one single execution** (F5 / Run Script)

> Do not split the SQL across multiple executions — the SQL Worksheet may reset the user between runs.

---

## Useful outputs

```bash
terraform output adb_id              # OCID of the ADB
terraform output adb_state           # Should be AVAILABLE
terraform output mongodb_api_host    # Hostname only
terraform output nestjs_env_snippet  # Full .env block (URI placeholder)
terraform output -raw mongo_uri_full # Full URI with password (sensitive)
terraform output manual_user_sql     # SQL to create the app user manually
```

---

## File structure

```
mongoOracleInfra/
├── providers.tf              # OCI provider (oracle/oci ~> 6.0)
├── variables.tf              # All input variables with descriptions
├── main.tf                   # Local values & connection string builder
├── database.tf               # ADB resource + curl/ORDS user provisioner
├── outputs.tf                # Connection info, .env snippet, manual SQL
├── terraform.tfvars.example  # Copy → terraform.tfvars and fill in
├── docs/
│   ├── infra-files.md                         # Per-file explanation of what each file does
│   ├── how-to-set-up-v1.md                   # End-to-end setup guide
│   ├── issue-fix-summaries/
│   │   ├── issue-fix-summary-01.md           # Issues from initial integration session
│   │   └── issue-fix-summary-02.md           # Issues from second-round automation test
│   └── worklogs/                              # Dated work logs
└── .gitignore                # Excludes *.tfvars, state files
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
- **MongoDB database name = Oracle username** — Oracle ADB constrains the MongoDB database name to match the authenticated user's schema. `MONGO_DB_NAME` must be `mongoapp`.
- **No retryable writes** — `retryWrites=false` is already set in the URI, but any write failures will not be automatically retried by the driver.
- **Time series collections** — The app's `dividends` and `price_ticks` schemas use MongoDB time series collections. Tested and confirmed working via the MongoDB API.

---

## Teardown

```bash
terraform destroy
```

This removes the ADB and all data. The OCI Always Free quota is restored after the instance is terminated.
