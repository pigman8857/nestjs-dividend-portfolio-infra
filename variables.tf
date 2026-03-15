# ── OCI Auth ───────────────────────────────────────────────────────────────────

variable "tenancy_ocid" {
  description = "OCI tenancy OCID"
  type        = string
}

variable "user_ocid" {
  description = "OCI user OCID"
  type        = string
}

variable "fingerprint" {
  description = "OCI API key fingerprint"
  type        = string
}

variable "private_key_path" {
  description = "Path to the OCI API private key (.pem)"
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  description = "OCI region (e.g. ap-singapore-1, us-ashburn-1)"
  type        = string
  default     = "ap-singapore-1"
}

variable "compartment_ocid" {
  description = "OCI compartment OCID where resources will be created"
  type        = string
}

# ── Project ────────────────────────────────────────────────────────────────────

variable "project_name" {
  description = "Short project name used as a prefix for resource display names"
  type        = string
  default     = "dividend-portfolio"
}

variable "environment" {
  description = "Environment label (e.g. dev, staging)"
  type        = string
  default     = "dev"
}

# ── Autonomous Database ────────────────────────────────────────────────────────

variable "adb_name" {
  description = <<-EOT
    Autonomous Database DB_NAME (alphanumeric, max 14 chars, no hyphens).
    This also forms part of the public MongoDB API hostname:
      <adb_name>.adb.<region>.oraclecloud.com
  EOT
  type        = string
  default     = "dividenddev"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9]{0,13}$", var.adb_name))
    error_message = "adb_name must start with a letter, be alphanumeric, and at most 14 characters."
  }
}

variable "adb_admin_password" {
  description = <<-EOT
    ADB ADMIN password. Must be 12-30 characters and contain at least one:
    uppercase letter, lowercase letter, digit, and special character.
    Example: MyP@ss123Dev!
  EOT
  type      = string
  sensitive = true
}

variable "adb_mongo_username" {
  description = <<-EOT
    Oracle DB user that the NestJS app will authenticate as via the
    MongoDB-compatible API. Created by Terraform after the ADB is up.
    Keep it short, uppercase internally but pass lowercase — Oracle normalises it.
  EOT
  type    = string
  default = "mongoapp"
}

variable "adb_mongo_password" {
  description = "Password for the MongoDB API application user (same complexity rules as admin)."
  type        = string
  sensitive   = true
}

variable "is_free_tier" {
  description = "Use the OCI Always Free Autonomous Database (20 GB, 2 ECPU). Ideal for dev/test."
  type        = bool
  default     = true
}

variable "adb_ecpu_count" {
  description = "ECPU count when is_free_tier = false. Min 2."
  type        = number
  default     = 2
}

variable "adb_storage_gb" {
  description = "Storage in GB. Always Free tier is capped at 20 GB."
  type        = number
  default     = 20
}

# ── Network access control ─────────────────────────────────────────────────────

variable "allowed_cidrs" {
  description = <<-EOT
    List of IP addresses or CIDR blocks allowed to reach the ADB on all ports
    (MongoDB API :27017 and TCPS :1522).
    For quick local testing you can set ["0.0.0.0/0"], but prefer restricting to
    your own public IP in dev and a VPC CIDR in production.
  EOT
  type    = list(string)
  default = ["0.0.0.0/0"]
}

