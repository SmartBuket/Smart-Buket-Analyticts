locals {
  cloud_armor_enabled = var.enable_perimeter && var.enable_cloudrun_services && var.cloud_armor_enable

  cloud_armor_allow_expr = length(var.cloud_armor_allow_ip_ranges) > 0 ? join(" || ", [
    for cidr in var.cloud_armor_allow_ip_ranges : "inIpRange(origin.ip, '${cidr}')"
  ]) : null

  cloud_armor_deny_expr = length(var.cloud_armor_deny_ip_ranges) > 0 ? join(" || ", [
    for cidr in var.cloud_armor_deny_ip_ranges : "inIpRange(origin.ip, '${cidr}')"
  ]) : null
}

resource "google_compute_security_policy" "perimeter" {
  count = local.cloud_armor_enabled ? 1 : 0

  name        = "sb-analytics-perimeter"
  description = "Perimeter policy for public entrypoint (Cloud Run behind HTTPS LB)"

  # Denylist first
  dynamic "rule" {
    for_each = local.cloud_armor_deny_expr != null ? [1] : []
    content {
      priority = 900
      action   = "deny(403)"
      match {
        expr {
          expression = local.cloud_armor_deny_expr
        }
      }
      description = "Denylisted IP ranges"
    }
  }

  # Allowlist (optional)
  dynamic "rule" {
    for_each = local.cloud_armor_allow_expr != null ? [1] : []
    content {
      priority = 1000
      action   = "allow"
      match {
        expr {
          expression = local.cloud_armor_allow_expr
        }
      }
      description = "Allowlisted IP ranges"
    }
  }

  # Rate limit (optional)
  dynamic "rule" {
    for_each = (var.cloud_armor_rate_limit_enabled ? [1] : [])
    content {
      priority = 1100
      action   = "allow"
      match {
        expr {
          expression = "true"
        }
      }
      rate_limit_options {
        conform_action = "allow"
        exceed_action  = "deny(429)"
        rate_limit_threshold {
          count        = var.cloud_armor_rate_limit_count
          interval_sec = var.cloud_armor_rate_limit_interval_sec
        }
      }
      description = "Basic rate limiting"
    }
  }

  # Default allow
  rule {
    priority = 2147483647
    action   = "allow"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow"
  }
}
