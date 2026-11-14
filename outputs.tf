output "gke_cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.task_manager.name
}

output "gke_cluster_location" {
  description = "Zone where the single-zone GKE cluster runs."
  value       = google_container_cluster.task_manager.location
}

output "gke_get_credentials_command" {
  description = "Run this command to configure kubectl for the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.task_manager.name} --zone ${google_container_cluster.task_manager.location} --project ${local.project_id}"
}

output "database_password" {
  description = "Generated application database password. Treat as a secret."
  value       = random_password.database.result
  sensitive   = true
}

output "database_private_ip" {
  description = "Private-only Cloud SQL address; reachable from the VPC."
  value       = google_sql_database_instance.task_manager.private_ip_address
}

output "database_name" {
  description = "Application database name."
  value       = google_sql_database.task_manager.name
}

output "vpc_name" {
  description = "VPC hosting the private GKE nodes and Cloud SQL private connection."
  value       = google_compute_network.task_manager.name
}
