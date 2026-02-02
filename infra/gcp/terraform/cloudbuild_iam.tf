data "google_project" "this" {}

locals {
  cloudbuild_sa = "serviceAccount:${data.google_project.this.number}@cloudbuild.gserviceaccount.com"
}

resource "google_service_account" "cloudbuild_deploy" {
  account_id   = "sb-cloudbuild-deploy"
  display_name = "SmartBuket Analytics - Cloud Build Deploy"

  depends_on = [google_project_service.required]
}

resource "google_service_account" "cloudbuild_bootstrap" {
  account_id   = "sb-cloudbuild-bootstrap"
  display_name = "SmartBuket Analytics - Cloud Build Bootstrap"

  depends_on = [google_project_service.required]
}

# Allow Cloud Build to push images to Artifact Registry.
resource "google_project_iam_member" "cloudbuild_artifactregistry_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.cloudbuild_deploy.email}"
}

# Allow Cloud Build to deploy/update Cloud Run services.
resource "google_project_iam_member" "cloudbuild_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.cloudbuild_deploy.email}"
}

# Allow Cloud Build to deploy services using the runtime service account.
resource "google_service_account_iam_member" "cloudbuild_impersonate_run_sa" {
  service_account_id = google_service_account.run.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cloudbuild_deploy.email}"
}

# Bootstrap SA: extra permissions needed to create remote state bucket, apply Terraform, init DB.
resource "google_project_iam_member" "cloudbuild_bootstrap_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.cloudbuild_bootstrap.email}"
}

resource "google_project_iam_member" "cloudbuild_bootstrap_serviceusage_admin" {
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageAdmin"
  member  = "serviceAccount:${google_service_account.cloudbuild_bootstrap.email}"
}

resource "google_project_iam_member" "cloudbuild_bootstrap_project_iam_admin" {
  project = var.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${google_service_account.cloudbuild_bootstrap.email}"
}

resource "google_project_iam_member" "cloudbuild_bootstrap_sa_admin" {
  project = var.project_id
  role    = "roles/iam.serviceAccountAdmin"
  member  = "serviceAccount:${google_service_account.cloudbuild_bootstrap.email}"
}

resource "google_project_iam_member" "cloudbuild_bootstrap_iam_security_admin" {
  project = var.project_id
  role    = "roles/iam.securityAdmin"
  member  = "serviceAccount:${google_service_account.cloudbuild_bootstrap.email}"
}

resource "google_project_iam_member" "cloudbuild_bootstrap_secretmanager_admin" {
  project = var.project_id
  role    = "roles/secretmanager.admin"
  member  = "serviceAccount:${google_service_account.cloudbuild_bootstrap.email}"
}

resource "google_project_iam_member" "cloudbuild_bootstrap_cloudsql_admin" {
  project = var.project_id
  role    = "roles/cloudsql.admin"
  member  = "serviceAccount:${google_service_account.cloudbuild_bootstrap.email}"
}

resource "google_project_iam_member" "cloudbuild_bootstrap_artifactregistry_admin" {
  project = var.project_id
  role    = "roles/artifactregistry.admin"
  member  = "serviceAccount:${google_service_account.cloudbuild_bootstrap.email}"
}

resource "google_project_iam_member" "cloudbuild_bootstrap_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.cloudbuild_bootstrap.email}"
}

resource "google_service_account_iam_member" "cloudbuild_bootstrap_impersonate_run_sa" {
  service_account_id = google_service_account.run.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cloudbuild_bootstrap.email}"
}
