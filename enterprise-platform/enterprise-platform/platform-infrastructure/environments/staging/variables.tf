variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region."
  type        = string
  default     = "asia-south1"
}

variable "zone" {
  description = "GCP zone. Nodes are pinned here so 2 nodes means 2 nodes."
  type        = string
  default     = "asia-south1-a"
}

variable "authorized_cidrs" {
  description = "CIDRs allowed to reach the GKE control plane."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "node_count" {
  description = "HARD REQUIREMENT: exactly 2 nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count == 2
    error_message = "This platform is specified for exactly 2 nodes."
  }
}

# ---- Sizing knobs ----
# Defaults are the comfortable profile (~550GB SSD, ~17 vCPU).
# See terraform.tfvars.free-trial if your project has low quotas.

variable "disk_type" {
  description = "pd-balanced counts against SSD_TOTAL_GB; pd-standard against DISKS_TOTAL_GB."
  type        = string
  default     = "pd-balanced"
}

variable "node_disk_size_gb" {
  type    = number
  default = 100
}

variable "machine_type" {
  description = "GKE node machine type."
  type        = string
  default     = "e2-standard-4"
}

variable "jenkins_controller_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "jenkins_agent_machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "sonarqube_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "jenkins_controller_disk_gb" {
  type    = number
  default = 50
}

variable "jenkins_home_disk_gb" {
  type    = number
  default = 100
}

variable "jenkins_agent_disk_gb" {
  type    = number
  default = 200
}

variable "sonarqube_disk_gb" {
  type    = number
  default = 50
}

variable "sonar_data_disk_gb" {
  type    = number
  default = 100
}
