variable "project_id" { type = string }
variable "region"     { type = string }
variable "env"        { type = string }

variable "subnet_cidr"        { type = string }
variable "pods_cidr"          { type = string }
variable "services_cidr"      { type = string }
variable "master_cidr"        { type = string }
variable "tooling_subnet_cidr"{ type = string }
