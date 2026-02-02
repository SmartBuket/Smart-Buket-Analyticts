locals {
  private_networking_enabled = var.enable_private_networking && var.enable_cloudsql
}

resource "google_compute_network" "vpc" {
  count = local.private_networking_enabled ? 1 : 0

  name                    = var.vpc_network_name
  auto_create_subnetworks = false

  depends_on = [google_project_service.required]
}

resource "google_compute_subnetwork" "subnet" {
  count = local.private_networking_enabled ? 1 : 0

  name          = "${var.vpc_network_name}-subnet"
  ip_cidr_range = var.vpc_subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc[0].id

  private_ip_google_access = true
}

# Needed for Cloud SQL private IP.
resource "google_compute_global_address" "private_service_range" {
  count = local.private_networking_enabled ? 1 : 0

  name          = "${var.vpc_network_name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc[0].id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  count = local.private_networking_enabled ? 1 : 0

  network                 = google_compute_network.vpc[0].id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range[0].name]

  depends_on = [google_project_service.required]
}

resource "google_vpc_access_connector" "serverless" {
  count = local.private_networking_enabled ? 1 : 0

  name          = var.vpc_connector_name
  region        = var.region
  network       = google_compute_network.vpc[0].name
  ip_cidr_range = var.vpc_connector_cidr

  min_instances = 2
  max_instances = 10

  depends_on = [google_project_service.required]
}
