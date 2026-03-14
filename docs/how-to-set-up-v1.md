# How to Set Up — v1

End-to-end guide: from a fresh OCI account to a running MongoDB-compatible ADB connected to the NestJS app.

---

## 1. Create an OCI account

1. Go to [cloud.oracle.com](https://cloud.oracle.com) → **Sign Up for Free**
2. Choose the **Always Free** tier — no credit card charges for this project
3. Pick a **Home Region** (e.g. `ap-singapore-1`) — cannot be changed later; must match `region` in your tfvars

---

## 2. Collect your tenancy & user OCIDs

| Value | Where to find it |
|---|---|
| **Tenancy OCID** | Top-right profile menu → **Tenancy: \<name\>** → copy **OCID** |
| **User OCID** | Top-right profile menu → **My profile** → copy **OCID** |

---

## 3. Generate an API key (for Terraform auth)

OCI Console → **My profile** → **API keys** → **Add API key**:

1. Choose **Generate API key pair**
2. Download both the **private key** (`.pem`) and the **public key**
3. Save the private key: `~/.oci/oci_api_key.pem`
4. Lock down permissions: `chmod 600 ~/.oci/oci_api_key.pem`
5. Copy the **Fingerprint** shown (format: `aa:bb:cc:dd:...`)

---

## 4. Get your Compartment OCID

**Identity & Security** → **Compartments**

Use the root compartment (same OCID as the tenancy), or create a dedicated one. Copy the OCID.

---

## 5. Install tools

```bash
# Terraform (required)
sudo apt install terraform          # Debian/Ubuntu
# brew install terraform            # macOS

# OCI CLI (optional — needed for automatic DB user creation)
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

# sqlplus (optional — same use case as OCI CLI)
# Install Oracle Instant Client:
# https://www.oracle.com/database/technologies/instant-client.html
```

> If OCI CLI or sqlplus are not installed, the DB user creation step will be skipped.
> See [Manual DB user fallback](#manual-db-user-fallback) below.

---

## 6. Configure OCI CLI (optional but recommended)

```bash
oci setup config
# Prompts for: tenancy OCID, user OCID, fingerprint, key path, region
# Writes to: ~/.oci/config
```

---

## 7. Clone and configure this project

```bash
git clone https://github.com/pigman8857/nestjs-dividend-portfolio-infra
cd nestjs-dividend-portfolio-infra

cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with the values collected in the steps above:

```hcl
tenancy_ocid     = "ocid1.tenancy.oc1..aaaa..."    # step 2
user_ocid        = "ocid1.user.oc1..aaaa..."        # step 2
fingerprint      = "aa:bb:cc:..."                   # step 3
private_key_path = "~/.oci/oci_api_key.pem"         # step 3
region           = "ap-singapore-1"                 # home region from step 1
compartment_ocid = "ocid1.compartment.oc1..aaaa..." # step 4

adb_admin_password = "AdminP@ss123!"    # 12-30 chars, upper + lower + digit + special
adb_mongo_password = "MongoP@ss123!"    # same complexity rules
```

Password rules for both `*_password` fields: 12–30 characters, must include at least one uppercase letter, one lowercase letter, one digit, and one special character.

---

## 8. Deploy

```bash
terraform init      # download OCI + random providers (~1 min)
terraform plan      # preview — should show 2 resources to create
terraform apply     # provision ADB (~3-5 min to reach AVAILABLE state)
```

---

## 9. Get the connection string

```bash
terraform output -raw mongo_uri_full
```

Paste the result into the NestJS app's `.env` file as `MONGO_URI`.

For the full `.env` block:

```bash
terraform output nestjs_env_snippet
```

---

## Manual DB user fallback

If OCI CLI or sqlplus were not installed when `terraform apply` ran, the DB user was not created automatically. Fix it manually:

1. Run: `terraform output manual_user_sql`
2. Copy the SQL output
3. Go to **OCI Console → Autonomous Database → your DB → Database Actions → SQL**
4. Sign in as **ADMIN** and paste + run the SQL

---

## Flow summary

```
OCI account
  └─ tenancy OCID + user OCID         (step 2)
  └─ API key → fingerprint + .pem     (step 3)
  └─ compartment OCID                 (step 4)
        │
        ▼
terraform.tfvars  ←  fill in all OCIDs + passwords
        │
        ▼
terraform apply
  ├─ creates ADB (ATP, Always Free, MongoDB API on :27017)
  └─ creates DB user MONGOAPP with required grants
        │
        ▼
terraform output -raw mongo_uri_full  →  NestJS .env MONGO_URI
```
