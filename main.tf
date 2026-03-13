locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  # MongoDB-compatible API hostname (public endpoint)
  # Oracle ADB exposes this automatically when is_mtls_connection_required = false
  adb_mongo_host = "${lower(var.adb_name)}.adb.${var.region}.oraclecloud.com"

  # Connection string the NestJS app should use as MONGO_URI
  # authMechanism=PLAIN  → Oracle uses LDAP/PLAIN for MongoDB API auth
  # authSource=$external → required for external (non-MongoDB-native) auth
  # ssl=true             → ADB requires TLS even in non-mTLS mode
  # retryWrites=false    → ADB MongoDB API does not support retryable writes
  # loadBalanced=true    → required for Oracle ADB multi-node routing
  mongo_uri = "mongodb://${var.adb_mongo_username}:$${MONGO_PASSWORD}@${local.adb_mongo_host}:27017/${var.mongo_db_name}?authMechanism=PLAIN&authSource=%24external&ssl=true&retryWrites=false&loadBalanced=true"

  # URI with password included — kept in Terraform state, retrieve via output only
  mongo_uri_with_password = "mongodb://${var.adb_mongo_username}:${var.adb_mongo_password}@${local.adb_mongo_host}:27017/${var.mongo_db_name}?authMechanism=PLAIN&authSource=%24external&ssl=true&retryWrites=false&loadBalanced=true"
}
