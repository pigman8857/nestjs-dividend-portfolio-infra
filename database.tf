# ── Autonomous Database (ATP) ──────────────────────────────────────────────────
#
# Oracle ATP (db_workload = OLTP) supports the MongoDB-compatible API out of the
# box on port 27017. No extra plug-ins are required. The key settings that make
# it work are:
#
#   is_mtls_connection_required = false   → enables TLS-only mode so Mongoose can
#                                           connect without downloading a wallet
#   whitelisted_ips             = [...]   → controls which IPs reach the instance
#
# The MongoDB API endpoint becomes available automatically at:
#   <adb_name>.adb.<region>.oraclecloud.com:27017
# ──────────────────────────────────────────────────────────────────────────────

resource "oci_database_autonomous_database" "adb" {
  compartment_id = var.compartment_ocid

  # Identification
  db_name      = var.adb_name
  display_name = "${local.name_prefix}-adb"

  # OLTP = Autonomous Transaction Processing (ATP).
  # ATP is the workload type that exposes the MongoDB-compatible API.
  db_workload = "OLTP"

  # Database version — 19c and 23ai both support MongoDB API.
  # 23ai adds more compatibility features (recommended when available in your region).
  db_version = "19c"

  # Credentials (ADMIN is the built-in super-user)
  admin_password = var.adb_admin_password

  # ── Compute & Storage ──────────────────────────────────────────────────────
  # Always Free tier: 2 ECPU, 20 GB — perfect for dev/test.
  # To use paid: set is_free_tier = false and adjust ecpu/storage.
  is_free_tier             = var.is_free_tier
  compute_model            = "ECPU"
  compute_count            = var.is_free_tier ? 2 : var.adb_ecpu_count
  data_storage_size_in_gbs = var.adb_storage_gb

  # ── Network access ─────────────────────────────────────────────────────────
  # PUBLIC access with an ACL (IP allowlist).
  # - is_mtls_connection_required = false lets Mongoose connect with a plain
  #   TLS certificate chain rather than a wallet + JKS trust store.
  # - whitelisted_ips restricts which sources can reach the instance.
  is_mtls_connection_required = false
  whitelisted_ips             = var.allowed_cidrs

  # License model — LICENSE_INCLUDED is the simpler choice for dev.
  # Use BRING_YOUR_OWN_LICENSE if your org has existing Oracle licences.
  license_model = "LICENSE_INCLUDED"

  freeform_tags = local.common_tags
}

# ── App DB user ────────────────────────────────────────────────────────────────
#
# Oracle ADB does not natively expose a Terraform resource to create DB users,
# so we use a null_resource + local-exec to call the OCI CLI after the ADB
# becomes AVAILABLE.
#
# The user is granted:
#   - CREATE SESSION                → basic login
#   - SODA_APP                      → SODA/MongoDB API collections
#   - CREATE TABLE, CREATE INDEX... → schema DDL for Mongoose models
#
# Prerequisites on the machine running Terraform:
#   - OCI CLI installed and configured (oci setup config)
#   - SQLcl or sqlplus (for the SQL block below) — OR remove this resource and
#     create the user manually after the first apply.
# ──────────────────────────────────────────────────────────────────────────────

resource "null_resource" "create_mongo_user" {
  depends_on = [oci_database_autonomous_database.adb]

  triggers = {
    adb_id   = oci_database_autonomous_database.adb.id
    username = var.adb_mongo_username
  }

  provisioner "local-exec" {
    # Downloads the wallet to a temp dir, then runs the SQL via sqlplus.
    # If sqlplus is not available, see outputs.tf for the manual SQL to run.
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -e
      WALLET_DIR=$(mktemp -d)
      ADB_ID="${oci_database_autonomous_database.adb.id}"
      USERNAME="${upper(var.adb_mongo_username)}"
      PASSWORD="${var.adb_mongo_password}"
      ADMIN_PASS="${var.adb_admin_password}"
      DB_NAME="${var.adb_name}"
      REGION="${var.region}"

      echo "==> Downloading ADB wallet..."
      oci db autonomous-database generate-wallet \
        --autonomous-database-id "$ADB_ID" \
        --password "WalletP@ss1" \
        --file "$WALLET_DIR/wallet.zip" \
        --region "$REGION" 2>/dev/null || {
          echo "WARNING: Could not download wallet via OCI CLI."
          echo "Please create the DB user manually — see outputs for SQL."
          exit 0
        }

      unzip -q "$WALLET_DIR/wallet.zip" -d "$WALLET_DIR/wallet"
      export TNS_ADMIN="$WALLET_DIR/wallet"
      TNS_ALIAS=$(grep -o "${upper(var.adb_name)}_[a-z]*" "$WALLET_DIR/wallet/tnsnames.ora" | head -1)

      echo "==> Creating Oracle DB user '$USERNAME' via sqlplus..."
      sqlplus -s "ADMIN/$ADMIN_PASS@$TNS_ALIAS" <<SQL 2>/dev/null || {
        echo "WARNING: sqlplus not found. Please run the user-creation SQL manually — see outputs."
      }
        CREATE USER "$USERNAME" IDENTIFIED BY "$PASSWORD";
        GRANT CREATE SESSION TO "$USERNAME";
        GRANT SODA_APP TO "$USERNAME";
        GRANT CREATE TABLE TO "$USERNAME";
        GRANT CREATE SEQUENCE TO "$USERNAME";
        GRANT CREATE INDEX TO "$USERNAME";
        GRANT CREATE VIEW TO "$USERNAME";
        ALTER USER "$USERNAME" QUOTA UNLIMITED ON DATA;
        COMMIT;
        EXIT;
      SQL
      rm -rf "$WALLET_DIR"
      echo "==> Done."
    BASH
  }
}
