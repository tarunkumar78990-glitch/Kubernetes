variable "project_id" {
  type = string
}

variable "env" {
  type = string
}

variable "namespace" {
  description = "Kubernetes namespace the KSA lives in."
  type        = string
}

variable "services" {
  description = "Map of service name -> list of GCP roles that service needs."
  type        = map(list(string))
}
