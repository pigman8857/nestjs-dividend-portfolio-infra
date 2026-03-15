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
  data_storage_size_in_tbs = var.is_free_tier ? null : ceil(var.adb_storage_gb / 1024)

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

  # OCI manages compute_count on Always Free databases — ignore drift.
  lifecycle {
    ignore_changes = [compute_count]
  }
}

# ── App DB user ────────────────────────────────────────────────────────────────
#
# Oracle ADB does not expose a Terraform resource to create DB users, so we
# use a null_resource + local-exec that POSTs SQL to the ORDS REST API
# (available on the ADB's public HTTPS endpoint — no OCI CLI or sqlplus needed).
#
# The user is granted:
#   - CREATE SESSION   → basic login
#   - SODA_APP         → SODA/MongoDB API collections
#   - CREATE TABLE     → schema DDL for Mongoose models
#   - CREATE SEQUENCE  → auto-increment fields
#   - CREATE VIEW      → views used by some Mongoose plugins
#
# ORDS.ENABLE_SCHEMA is called after the grants — required for the MongoDB
# wire protocol to accept connections from this user.
#
# Fallback: if curl is unavailable, run 'terraform output manual_user_sql'
# and execute the result in OCI Console → Database Actions → SQL (as ADMIN).
# ──────────────────────────────────────────────────────────────────────────────

resource "null_resource" "create_mongo_user" {
  depends_on = [oci_database_autonomous_database.adb]

  triggers = {
    adb_id   = oci_database_autonomous_database.adb.id
    username = var.adb_mongo_username
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -e
      ORDS_BASE="${oci_database_autonomous_database.adb.connection_urls[0].ords_url}"
      SQL_URL="$${ORDS_BASE}admin/_/sql"
      USERNAME="${upper(var.adb_mongo_username)}"
      USERNAME_LOWER="${lower(var.adb_mongo_username)}"
      PASSWORD="${var.adb_mongo_password}"
      ADMIN_PASS="${var.adb_admin_password}"

      if ! command -v curl &>/dev/null; then
        echo "WARNING: curl not found. Please create the DB user manually:"
        echo "  terraform output manual_user_sql"
        exit 0
      fi

      echo "==> Creating DB user '$${USERNAME}' via ORDS REST API..."
      USER_SQL="CREATE USER $${USERNAME} IDENTIFIED BY \"$${PASSWORD}\";
GRANT CREATE SESSION TO $${USERNAME};
GRANT SODA_APP TO $${USERNAME};
GRANT CREATE TABLE TO $${USERNAME};
GRANT CREATE SEQUENCE TO $${USERNAME};
GRANT CREATE VIEW TO $${USERNAME};
ALTER USER $${USERNAME} QUOTA UNLIMITED ON DATA;"

      curl -sf -X POST "$${SQL_URL}" \
        -H "Content-Type: application/sql" \
        --user "ADMIN:$${ADMIN_PASS}" \
        --data-binary "$${USER_SQL}" \
        -o /dev/null || {
          echo "WARNING: ORDS user-creation call failed."
          echo "Please create the DB user manually: terraform output manual_user_sql"
          exit 0
        }

      echo "==> Enabling ORDS schema for MongoDB API access..."
      ORDS_SQL="BEGIN
  ORDS.ENABLE_SCHEMA(
    p_enabled             => TRUE,
    p_schema              => '$${USERNAME}',
    p_url_mapping_type    => 'BASE_PATH',
    p_url_mapping_pattern => '$${USERNAME_LOWER}',
    p_auto_rest_auth      => TRUE
  );
  COMMIT;
END;"

      curl -sf -X POST "$${SQL_URL}" \
        -H "Content-Type: application/sql" \
        --user "ADMIN:$${ADMIN_PASS}" \
        --data-binary "$${ORDS_SQL}" \
        -o /dev/null || {
          echo "WARNING: ORDS.ENABLE_SCHEMA call failed."
          echo "Please run manually: terraform output manual_user_sql"
          exit 0
        }

      echo "==> Done. DB user '$${USERNAME}' created with MongoDB API access."
    BASH
  }
}
