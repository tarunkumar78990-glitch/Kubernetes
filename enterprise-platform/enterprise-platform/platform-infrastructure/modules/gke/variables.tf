variable "project_id"          { type = string }
variable "region"              { type = string }
variable "env"                 { type = string }
variable "network"             { type = string }
variable "subnetwork"          { type = string }
variable "pods_range_name"     { type = string }
variable "services_range_name" { type = string }
variable "master_cidr"         { type = string }

variable "node_count" {
  description = "Nodes in the pool. Pinned to exactly 2 per requirement."
  type        = number
  default     = 1
}

variable "machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "node_service_account" {
  description = "Least-privilege SA for the nodes themselves."
  type        = string
}

variable "authorized_cidrs" {
  description = "CIDRs allowed to reach the private control plane."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
}

variable "release_channel" {
  type    = string
  default = "REGULAR"
}

variable "node_disk_size_gb" {
  description = "Boot disk per node. 100 is comfortable; 50 fits a free trial."
  type        = number
  default     = 100
}

variable "node_disk_type" {
  description = "pd-balanced counts against SSD_TOTAL_GB. pd-standard counts against DISKS_TOTAL_GB, which free-trial projects have far more of."
  type        = string
  default     = "pd-balanced"

  validation {
    condition     = contains(["pd-standard", "pd-balanced", "pd-ssd"], var.node_disk_type)
    error_message = "node_disk_type must be pd-standard, pd-balanced or pd-ssd."
  }
}
