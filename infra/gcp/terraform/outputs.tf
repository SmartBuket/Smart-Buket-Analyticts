output "artifact_registry_repo" {
  value       = google_artifact_registry_repository.repo.name
  description = "Artifact Registry repository resource name"
}

output "cloud_run_urls" {
  value = {
    for name, svc in google_cloud_run_v2_service.svc :
    name => svc.uri
  }
  description = "Deployed Cloud Run service URLs"
}

output "cloud_run_service_account" {
  value       = google_service_account.run.email
  description = "Service account used by Cloud Run services"
}

output "perimeter_ip" {
  value       = try(google_compute_global_address.perimeter_ip[0].address, null)
  description = "External IP address for the HTTPS load balancer perimeter (if enabled)"
}

output "perimeter_url" {
  value = (
    var.perimeter_domain != null && length(trimspace(var.perimeter_domain)) > 0
    ? "https://${var.perimeter_domain}"
    : (try(google_compute_global_address.perimeter_ip[0].address, null) != null ? "http://${google_compute_global_address.perimeter_ip[0].address}" : null)
  )
  description = "Perimeter base URL (domain if configured, otherwise IP)"
}
