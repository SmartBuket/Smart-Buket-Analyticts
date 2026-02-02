locals {
  perimeter_enabled = var.enable_perimeter && var.enable_cloudrun_services
  perimeter_https   = local.perimeter_enabled && var.perimeter_enable_https && var.perimeter_domain != null && length(trimspace(var.perimeter_domain)) > 0
}

resource "google_compute_global_address" "perimeter_ip" {
  count = local.perimeter_enabled ? 1 : 0

  name = "sb-analytics-perimeter-ip"

  depends_on = [google_project_service.required]
}

resource "google_compute_region_network_endpoint_group" "perimeter_neg" {
  count = local.perimeter_enabled ? 1 : 0

  name                  = "sb-${var.perimeter_service_name}-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.svc[var.perimeter_service_name].name
  }

  depends_on = [google_project_service.required]
}

resource "google_compute_backend_service" "perimeter_backend" {
  count = local.perimeter_enabled ? 1 : 0

  name                  = "sb-analytics-perimeter-backend"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.perimeter_neg[0].id
  }

  security_policy = (var.cloud_armor_enable ? google_compute_security_policy.perimeter[0].id : null)

  depends_on = [google_project_service.required]
}

resource "google_compute_url_map" "perimeter_urlmap" {
  count = local.perimeter_enabled ? 1 : 0

  name            = "sb-analytics-perimeter-urlmap"
  default_service = google_compute_backend_service.perimeter_backend[0].id
}

resource "google_compute_target_http_proxy" "perimeter_http_proxy" {
  count = local.perimeter_enabled ? 1 : 0

  name    = "sb-analytics-perimeter-http-proxy"
  url_map = google_compute_url_map.perimeter_urlmap[0].id
}

resource "google_compute_managed_ssl_certificate" "perimeter_cert" {
  count = local.perimeter_https ? 1 : 0

  name = "sb-analytics-perimeter-cert"

  managed {
    domains = [var.perimeter_domain]
  }
}

resource "google_compute_target_https_proxy" "perimeter_https_proxy" {
  count = local.perimeter_https ? 1 : 0

  name             = "sb-analytics-perimeter-https-proxy"
  url_map          = google_compute_url_map.perimeter_urlmap[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.perimeter_cert[0].id]
}

# Forwarding rules
resource "google_compute_global_forwarding_rule" "perimeter_https" {
  count = local.perimeter_https ? 1 : 0

  name                  = "sb-analytics-perimeter-https"
  ip_address            = google_compute_global_address.perimeter_ip[0].address
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_https_proxy.perimeter_https_proxy[0].id
}

# Optional HTTP->HTTPS redirect
resource "google_compute_url_map" "perimeter_redirect" {
  count = (local.perimeter_https && var.perimeter_enable_http_redirect) ? 1 : 0

  name = "sb-analytics-perimeter-redirect"

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "perimeter_http_redirect_proxy" {
  count = (local.perimeter_https && var.perimeter_enable_http_redirect) ? 1 : 0

  name    = "sb-analytics-perimeter-http-redirect"
  url_map = google_compute_url_map.perimeter_redirect[0].id
}

resource "google_compute_global_forwarding_rule" "perimeter_http" {
  count = local.perimeter_enabled ? 1 : 0

  name                  = "sb-analytics-perimeter-http"
  ip_address            = google_compute_global_address.perimeter_ip[0].address
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target = (
    (local.perimeter_https && var.perimeter_enable_http_redirect)
    ? google_compute_target_http_proxy.perimeter_http_redirect_proxy[0].id
    : google_compute_target_http_proxy.perimeter_http_proxy[0].id
  )
}
