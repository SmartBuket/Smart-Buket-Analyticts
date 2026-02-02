locals {
  services = {
    ingest-api = {
      image = var.images.ingest_api
      port  = 8080
    }
    query-api = {
      image = var.images.query_api
      port  = 8080
    }
    reco-api = {
      image = var.images.reco_api
      port  = 8080
    }
    processor = {
      image = var.images.processor
      port  = 8080
    }
    outbox-publisher = {
      image = var.images.outbox_publisher
      port  = 8080
    }
  }

  cloud_run_services = var.enable_cloudrun_services ? local.services : {}

  public_cloud_run_services = {
    for k, v in local.cloud_run_services : k => v
    if contains(var.public_service_names, k)
  }

  effective_env = {
    for k, v in var.env : k => v
    if !(
      (var.enable_cloudsql && k == "SB_POSTGRES_DSN") ||
      (var.enable_rabbitmq_secret && k == "SB_RABBITMQ_URL")
    )
  }
}

resource "google_project_service" "required" {
  for_each = toset([
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "compute.googleapis.com",
    "vpcaccess.googleapis.com",
    "servicenetworking.googleapis.com",
  ])

  project = var.project_id
  service = each.value

  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = var.artifact_repo
  description   = "SmartBuket Analytics container images"
  format        = "DOCKER"

  depends_on = [google_project_service.required]
}

resource "google_service_account" "run" {
  account_id   = var.service_account_name
  display_name = "SmartBuket Analytics - Cloud Run"

  depends_on = [google_project_service.required]
}

resource "google_cloud_run_v2_service" "svc" {
  for_each = local.cloud_run_services

  name     = each.key
  location = var.region

  ingress = var.cloudrun_ingress

  template {
    service_account = google_service_account.run.email

    dynamic "vpc_access" {
      for_each = (var.enable_private_networking && var.enable_cloudsql) ? [1] : []
      content {
        connector = google_vpc_access_connector.serverless[0].id
        egress    = "PRIVATE_RANGES_ONLY"
      }
    }

    dynamic "volumes" {
      for_each = var.enable_cloudsql ? [1] : []
      content {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.postgres[0].connection_name]
        }
      }
    }

    containers {
      image = each.value.image

      ports {
        container_port = each.value.port
      }

      dynamic "env" {
        for_each = local.effective_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.enable_cloudsql ? [1] : []
        content {
          name = "SB_POSTGRES_DSN"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.sb_postgres_dsn[0].secret_id
              version = "latest"
            }
          }
        }
      }

      dynamic "env" {
        for_each = var.enable_rabbitmq_secret ? [1] : []
        content {
          name = "SB_RABBITMQ_URL"
          value_source {
            secret_key_ref {
              secret  = var.rabbitmq_secret_id
              version = "latest"
            }
          }
        }
      }

      dynamic "volume_mounts" {
        for_each = var.enable_cloudsql ? [1] : []
        content {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }
  }

  depends_on = [
    google_project_service.required,
    google_project_iam_member.run_cloudsql_client,
    google_secret_manager_secret_iam_member.sb_postgres_dsn_accessor,
    google_secret_manager_secret_iam_member.sb_rabbitmq_url_accessor,
    google_vpc_access_connector.serverless,
  ]
}

# Public (optional)
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  for_each = (var.allow_unauthenticated || var.enable_perimeter) ? local.public_cloud_run_services : {}

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.svc[each.key].name

  role   = "roles/run.invoker"
  member = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "member_invoker" {
  for_each = {
    for pair in setproduct(keys(local.cloud_run_services), var.invoker_members) :
    "${pair[0]}::${pair[1]}" => { service = pair[0], member = pair[1] }
  }

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.svc[each.value.service].name

  role   = "roles/run.invoker"
  member = each.value.member
}
