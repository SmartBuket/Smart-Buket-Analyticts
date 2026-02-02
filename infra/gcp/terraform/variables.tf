variable "project_id" {
  type        = string
  description = "GCP project id"
}

variable "region" {
  type        = string
  description = "GCP region"
  default     = "us-central1"
}

variable "artifact_repo" {
  type        = string
  description = "Artifact Registry repository name"
  default     = "sb-analytics"
}

variable "service_account_name" {
  type        = string
  description = "Cloud Run service account id (without domain)"
  default     = "sb-analytics-run"
}

variable "images" {
  type = object({
    ingest_api       = string
    query_api        = string
    reco_api         = string
    processor        = string
    outbox_publisher = string
  })
  description = "Container image URLs for each service"

  default = {
    ingest_api       = ""
    query_api        = ""
    reco_api         = ""
    processor        = ""
    outbox_publisher = ""
  }

  validation {
    condition = (
      !var.enable_cloudrun_services ||
      alltrue([for v in values(tomap(var.images)) : length(trimspace(v)) > 0])
    )
    error_message = "When enable_cloudrun_services=true, all images.* values must be non-empty."
  }
}

variable "env" {
  type        = map(string)
  description = "Plain env vars injected into Cloud Run services (use Secret Manager for prod)"
  default     = {}
}

variable "allow_unauthenticated" {
  type        = bool
  description = "If true, allow unauthenticated invocations (public). Prefer false with API Gateway/IAP/JWT."
  default     = false
}

variable "invoker_members" {
  type        = list(string)
  description = "Additional IAM members granted roles/run.invoker on all Cloud Run services (e.g. serviceAccount:api-gw@PROJECT.iam.gserviceaccount.com)."
  default     = []
}

variable "cloudrun_ingress" {
  type        = string
  description = "Cloud Run ingress setting. Recommended: INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER (use API Gateway/LB)."
  default     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
}

variable "public_service_names" {
  type        = list(string)
  description = "Cloud Run services that are allowed to be invoked without Cloud Run IAM auth (still typically protected by JWT at app layer + Cloud Armor at LB)."
  default     = ["ingest-api"]
}

variable "enable_perimeter" {
  type        = bool
  description = "If true, creates an external HTTPS Load Balancer + Cloud Armor pointing at perimeter_service_name."
  default     = true
}

variable "perimeter_service_name" {
  type        = string
  description = "Cloud Run service exposed via the perimeter load balancer"
  default     = "ingest-api"
}

variable "perimeter_domain" {
  type        = string
  description = "Domain for managed SSL cert (optional). If unset, the LB will be HTTP-only."
  default     = null
}

variable "perimeter_enable_https" {
  type        = bool
  description = "If true and perimeter_domain is set, create HTTPS listener with managed cert."
  default     = true
}

variable "perimeter_enable_http_redirect" {
  type        = bool
  description = "If true, HTTP (80) redirects to HTTPS when HTTPS is enabled."
  default     = true
}

variable "cloud_armor_enable" {
  type        = bool
  description = "Attach Cloud Armor policy to the perimeter load balancer backend."
  default     = true
}

variable "cloud_armor_allow_ip_ranges" {
  type        = list(string)
  description = "Optional IP allowlist CIDRs. If set, only these IPs are allowed (unless you add more rules)."
  default     = []
}

variable "cloud_armor_deny_ip_ranges" {
  type        = list(string)
  description = "Optional IP denylist CIDRs. Denied with 403."
  default     = []
}

variable "cloud_armor_rate_limit_enabled" {
  type        = bool
  description = "Enable basic rate limiting at the perimeter."
  default     = true
}

variable "cloud_armor_rate_limit_count" {
  type        = number
  description = "Requests per interval allowed before 429."
  default     = 600
}

variable "cloud_armor_rate_limit_interval_sec" {
  type        = number
  description = "Rate limit interval in seconds."
  default     = 60
}

variable "enable_cloudrun_services" {
  type        = bool
  description = "If true, create Cloud Run services in Terraform. Set false for bootstrap (create infra first, then build images)."
  default     = true
}

variable "enable_cloudsql" {
  type        = bool
  description = "If true, provision Cloud SQL Postgres and inject SB_POSTGRES_DSN from Secret Manager."
  default     = true
}

variable "cloudsql_instance_name" {
  type        = string
  description = "Cloud SQL instance name"
  default     = "sb-analytics-pg"
}

variable "cloudsql_database_name" {
  type        = string
  description = "Application database name"
  default     = "sb_analytics"
}

variable "cloudsql_user" {
  type        = string
  description = "Application database user"
  default     = "sb_app"
}

variable "cloudsql_tier" {
  type        = string
  description = "Machine tier (override per environment)"
  default     = "db-custom-1-3840"
}

variable "cloudsql_disk_size_gb" {
  type        = number
  description = "Disk size in GB"
  default     = 20
}

variable "cloudsql_deletion_protection" {
  type        = bool
  description = "Protect instance from accidental deletion"
  default     = false
}

variable "cloudsql_enable_public_ip" {
  type        = bool
  description = "If true, Cloud SQL will have a public IPv4 address. Needed for Cloud Build DB init unless you use a private pool/VPC. Prefer false for production."
  default     = true

  validation {
    condition     = !(var.enable_private_networking && var.cloudsql_enable_public_ip)
    error_message = "When enable_private_networking=true, set cloudsql_enable_public_ip=false (use Private IP only)."
  }
}

variable "enable_private_networking" {
  type        = bool
  description = "If true, creates a dedicated VPC + Serverless VPC Connector and enables Cloud SQL private IP. Recommended for production."
  default     = false
}

variable "vpc_network_name" {
  type        = string
  description = "VPC name used when enable_private_networking=true"
  default     = "sb-analytics-vpc"
}

variable "vpc_subnet_cidr" {
  type        = string
  description = "Subnet CIDR for the VPC (region subnet)"
  default     = "10.10.0.0/24"
}

variable "vpc_connector_name" {
  type        = string
  description = "Serverless VPC Access connector name"
  default     = "sb-analytics-conn"
}

variable "vpc_connector_cidr" {
  type        = string
  description = "CIDR for Serverless VPC Access connector (must not overlap with subnet)"
  default     = "10.8.0.0/28"
}

variable "rabbitmq_url" {
  type        = string
  description = "RabbitMQ connection URL (amqp/amqps). Used only when manage_rabbitmq_secret=true to create/update the secret."
  sensitive   = true
  default     = null
}

variable "rabbitmq_secret_id" {
  type        = string
  description = "Secret Manager secret id that holds the RabbitMQ URL (used when manage_rabbitmq_secret=false)."
  default     = "sb-rabbitmq-url"
}

variable "manage_rabbitmq_secret" {
  type        = bool
  description = "If true, Terraform will create the RabbitMQ secret and set its version from rabbitmq_url. If false, it will reference an existing secret."
  default     = false
}

variable "enable_rabbitmq_secret" {
  type        = bool
  description = "If true, inject SB_RABBITMQ_URL from Secret Manager into Cloud Run services."
  default     = true
}
