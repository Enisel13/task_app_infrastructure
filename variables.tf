variable "project_id" {
  description = "Google Cloud project ID with billing enabled."
  type        = string
  default     = "cybernetic-tide-474909-n0"
}

variable "region" {
  description = "Region for the network, NAT, and Cloud SQL."
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "Zone for the single-zone, lower-cost GKE cluster."
  type        = string
  default     = "europe-west1-b"
}

variable "network_name" {
  description = "Name of the VPC network."
  type        = string
  default     = "task-manager-vpc"
}

variable "public_subnet_cidr" {
  description = "Primary IP range reserved for public-facing resources."
  type        = string
  default     = "10.10.0.0/20"
}

variable "private_subnet_cidr" {
  description = "Primary IP range for private GKE nodes."
  type        = string
  default     = "10.20.0.0/20"
}

variable "pod_cidr" {
  description = "Secondary IP range for GKE pods."
  type        = string
  default     = "10.30.0.0/16"
}

variable "service_cidr" {
  description = "Secondary IP range for Kubernetes services."
  type        = string
  default     = "10.40.0.0/20"
}

variable "cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
  default     = "task-manager-gke"
}

variable "gke_node_count" {
  description = "Number of nodes in the single-zone GKE node pool."
  type        = number
  default     = 1
}

variable "gke_machine_type" {
  description = "Machine type for GKE worker nodes."
  type        = string
  default     = "e2-medium"
}

variable "database_instance_name" {
  description = "Name of the Cloud SQL instance."
  type        = string
  default     = "task-manager-mysql"
}

variable "database_name" {
  description = "Application database name."
  type        = string
  default     = "tasks_db"
}

variable "database_username" {
  description = "Dedicated application database username."
  type        = string
  default     = "task_app"
}

variable "database_tier" {
  description = "Cloud SQL machine tier. db-f1-micro is a low-cost development tier."
  type        = string
  default     = "db-f1-micro"
}

variable "database_deletion_protection" {
  description = "Protect the database from accidental Terraform deletion."
  type        = bool
  default     = false
}
