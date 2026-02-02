locals {
  cloudsql_connection_name = var.enable_cloudsql ? google_sql_database_instance.postgres[0].connection_name : null

  # Cloud Run + Cloud SQL connector DSN using Unix socket.
  # Example host: /cloudsql/<project>:<region>:<instance>
  postgres_dsn = var.enable_cloudsql ? "postgresql+psycopg://${var.cloudsql_user}:${random_password.cloudsql_user_password.result}@/${var.cloudsql_database_name}?host=/cloudsql/${google_sql_database_instance.postgres[0].connection_name}" : null

  rabbitmq_secret_enabled = var.enable_rabbitmq_secret
}

resource "google_secret_manager_secret" "sb_postgres_dsn" {
  count = var.enable_cloudsql ? 1 : 0

  secret_id = "sb-postgres-dsn"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "sb_postgres_dsn" {
  count = var.enable_cloudsql ? 1 : 0

  secret      = google_secret_manager_secret.sb_postgres_dsn[0].id
  secret_data = local.postgres_dsn
}

resource "google_secret_manager_secret_iam_member" "sb_postgres_dsn_accessor" {
  count = var.enable_cloudsql ? 1 : 0

  secret_id = google_secret_manager_secret.sb_postgres_dsn[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.run.email}"
}

resource "google_secret_manager_secret" "sb_postgres_admin_password" {
  count = var.enable_cloudsql ? 1 : 0

  secret_id = "sb-postgres-admin-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "sb_postgres_admin_password" {
  count = var.enable_cloudsql ? 1 : 0

  secret      = google_secret_manager_secret.sb_postgres_admin_password[0].id
  secret_data = random_password.cloudsql_postgres_password.result
}

resource "google_secret_manager_secret_iam_member" "sb_postgres_admin_password_bootstrap_reader" {
  count = var.enable_cloudsql ? 1 : 0

  secret_id = google_secret_manager_secret.sb_postgres_admin_password[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloudbuild_bootstrap.email}"
}

locals {
  manage_rabbitmq_secret = local.rabbitmq_secret_enabled && var.manage_rabbitmq_secret
  use_existing_rabbitmq  = local.rabbitmq_secret_enabled && !var.manage_rabbitmq_secret
}

data "google_secret_manager_secret" "sb_rabbitmq_url" {
  count = local.use_existing_rabbitmq ? 1 : 0

  secret_id = var.rabbitmq_secret_id
}

resource "google_secret_manager_secret" "sb_rabbitmq_url" {
  count = local.manage_rabbitmq_secret ? 1 : 0

  secret_id = var.rabbitmq_secret_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "sb_rabbitmq_url" {
  count = local.manage_rabbitmq_secret ? 1 : 0

  secret      = google_secret_manager_secret.sb_rabbitmq_url[0].id
  secret_data = var.rabbitmq_url
}

resource "google_secret_manager_secret_iam_member" "sb_rabbitmq_url_accessor" {
  count = local.rabbitmq_secret_enabled ? 1 : 0

  secret_id = local.manage_rabbitmq_secret ? google_secret_manager_secret.sb_rabbitmq_url[0].id : data.google_secret_manager_secret.sb_rabbitmq_url[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.run.email}"
}
