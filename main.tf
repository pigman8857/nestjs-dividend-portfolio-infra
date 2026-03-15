locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  # OCI assigns a tenancy-prefixed hostname that cannot be predicted from adb_name alone.
  # e.g. G384A9A0B4990AA-DIVIDENDDEV.adb.ap-singapore-1.oraclecloudapps.com
  # Read it directly from the resource's connection_urls instead of constructing it.
  _mongo_db_url_template = oci_database_autonomous_database.adb.connection_urls[0].mongo_db_url

  # Extract host from OCI template URL: "mongodb://[user:password@]HOST:27017/..."
  adb_mongo_host = regex("@\\]([^:]+):", local._mongo_db_url_template)[0]

  # Substitute OCI's placeholders with actual credentials.
  # authMechanism=PLAIN  → Oracle uses LDAP/PLAIN for MongoDB API auth
  # authSource=$external → required for external (non-MongoDB-native) auth
  # ssl=true             → ADB requires TLS even in non-mTLS mode
  # retryWrites=false    → ADB MongoDB API does not support retryable writes
  # loadBalanced=true    → required for Oracle ADB multi-node routing
  #
  # NOTE: Oracle ADB requires the MongoDB database name to match the
  # authenticated user's schema name. OCI's template uses "/[user]" for this.
  # We replace it with the username, not a separate db name variable.
  mongo_uri = replace(
    replace(local._mongo_db_url_template, "[user:password@]", "${var.adb_mongo_username}:$${MONGO_PASSWORD}@"),
    "/[user]", "/${var.adb_mongo_username}"
  )

  # URI with password included — kept in Terraform state, retrieve via output only
  mongo_uri_with_password = replace(
    replace(local._mongo_db_url_template, "[user:password@]", "${var.adb_mongo_username}:${var.adb_mongo_password}@"),
    "/[user]", "/${var.adb_mongo_username}"
  )
}
