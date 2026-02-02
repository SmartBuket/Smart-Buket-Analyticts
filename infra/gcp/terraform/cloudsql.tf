resource "random_password" "cloudsql_user_password" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "cloudsql_postgres_password" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_sql_database_instance" "postgres" {
  count = var.enable_cloudsql ? 1 : 0

  name             = var.cloudsql_instance_name
  database_version = "POSTGRES_16"
  region           = var.region

  settings {
    tier = var.cloudsql_tier

    disk_type       = "PD_SSD"
    disk_size       = var.cloudsql_disk_size_gb
    disk_autoresize = true

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
    }

    maintenance_window {
      day  = 7
      hour = 3
    }

    ip_configuration {
      ipv4_enabled    = var.cloudsql_enable_public_ip
      require_ssl     = true
      private_network = (var.enable_private_networking ? google_compute_network.vpc[0].id : null)
    }

    insights_config {
      query_insights_enabled = true
    }
  }

  deletion_protection = var.cloudsql_deletion_protection

  depends_on = [
    google_project_service.required,
    google_service_networking_connection.private_vpc_connection,
  ]
}

resource "google_sql_database" "app" {
  count = var.enable_cloudsql ? 1 : 0

  name     = var.cloudsql_database_name
  instance = google_sql_database_instance.postgres[0].name
}

resource "google_sql_user" "app" {
  count = var.enable_cloudsql ? 1 : 0

  name     = var.cloudsql_user
  instance = google_sql_database_instance.postgres[0].name
  password = random_password.cloudsql_user_password.result
}

# Set/rotate the built-in postgres user password so we can run init.sql during bootstrap.
resource "google_sql_user" "postgres" {
  count = var.enable_cloudsql ? 1 : 0

  name     = "postgres"
  instance = google_sql_database_instance.postgres[0].name
  password = random_password.cloudsql_postgres_password.result
}

# Cloud Run needs this role to connect to Cloud SQL via the connector/socket.
resource "google_project_iam_member" "run_cloudsql_client" {
  count = var.enable_cloudsql ? 1 : 0

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.run.email}"
}
