terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

data "http" "public_ip" {
  url = "https://api.ipify.org"
}

resource "random_password" "database" {
  length           = 32
  special          = true
  override_special = "!#%*-_=+?"
}

locals {
  project_id = var.project_id

  required_apis = toset([
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
  ])
}

resource "google_project_service" "apis" {
  for_each           = local.required_apis
  project            = local.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_network" "task_manager" {
  name                    = var.network_name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "public" {
  name                     = "${var.network_name}-public"
  region                   = var.region
  network                  = google_compute_network.task_manager.id
  ip_cidr_range            = var.public_subnet_cidr
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "private" {
  name                     = "${var.network_name}-private"
  region                   = var.region
  network                  = google_compute_network.task_manager.id
  ip_cidr_range            = var.private_subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = var.pod_cidr
  }

  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = var.service_cidr
  }
}

resource "google_compute_router" "task_manager" {
  name    = "${var.network_name}-router"
  region  = var.region
  network = google_compute_network.task_manager.id
}

resource "google_compute_router_nat" "task_manager" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.task_manager.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

resource "google_compute_global_address" "private_services" {
  name          = "${var.network_name}-private-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.task_manager.id
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.task_manager.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
  depends_on              = [google_project_service.apis]
}

resource "google_sql_database_instance" "task_manager" {
  name                = var.database_instance_name
  region              = var.region
  database_version    = "MYSQL_8_0"
  deletion_protection = var.database_deletion_protection

  settings {
    tier              = var.database_tier
    availability_type = "ZONAL"
    disk_autoresize   = true
    disk_size         = 20
    disk_type         = "PD_SSD"

    backup_configuration {
      enabled            = true
      binary_log_enabled = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.task_manager.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }

  depends_on = [google_service_networking_connection.private_services]
}

resource "google_sql_database" "task_manager" {
  name     = var.database_name
  instance = google_sql_database_instance.task_manager.name
}

resource "google_sql_user" "application" {
  name     = var.database_username
  instance = google_sql_database_instance.task_manager.name
  password = random_password.database.result
}

resource "google_service_account" "gke_nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE node service account"
}

resource "google_project_iam_member" "gke_node_logging" {
  project = local.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_node_monitoring" {
  project = local.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_container_cluster" "task_manager" {
  name                     = var.cluster_name
  location                 = var.zone
  network                  = google_compute_network.task_manager.id
  subnetwork               = google_compute_subnetwork.private.id
  networking_mode          = "VPC_NATIVE"
  deletion_protection      = false
  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods"
    services_secondary_range_name = "gke-services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "${trimspace(data.http.public_ip.response_body)}/32"
      display_name = "Terraform deployment workstation"
    }
  }

  workload_identity_config {
    workload_pool = "${local.project_id}.svc.id.goog"
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.gke_node_logging,
    google_project_iam_member.gke_node_monitoring,
  ]
}

resource "google_container_node_pool" "task_manager" {
  name       = "${var.cluster_name}-nodes"
  location   = var.zone
  cluster    = google_container_cluster.task_manager.name
  node_count = var.gke_node_count

  node_config {
    machine_type    = var.gke_machine_type
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
