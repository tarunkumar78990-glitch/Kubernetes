variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "zone" {
  type = string
}

variable "env" {
  type = string
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "bastion_sa_email" {
  type = string
}

variable "jenkins_controller_sa_email" {
  type = string
}

variable "jenkins_agent_sa_email" {
  type = string
}

variable "sonarqube_sa_email" {
  type = string
}

variable "bastion_machine_type" {
  type    = string
  default = "e2-micro"
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

# ---- Disk sizing ----
# Defaults are the comfortable profile. See terraform.tfvars.free-trial for a
# set that fits a 250GB SSD_TOTAL_GB limit.
#
# pd-balanced -> SSD_TOTAL_GB quota
# pd-standard -> DISKS_TOTAL_GB quota (much larger on free-trial projects)

variable "disk_type" {
  description = "Disk type for tooling boot disks and data disks."
  type        = string
  default     = "pd-balanced"
}

variable "jenkins_controller_disk_gb" {
  type    = number
  default = 20
}

variable "jenkins_home_disk_gb" {
  type    = number
  default = 20
}

variable "jenkins_agent_disk_gb" {
  description = "Docker layers eat disk. Below ~60GB you will hit no-space-left mid-build."
  type        = number
  default     = 20
}

variable "sonarqube_disk_gb" {
  type    = number
  default = 20
}

variable "sonar_data_disk_gb" {
  type    = number
  default = 20
}
