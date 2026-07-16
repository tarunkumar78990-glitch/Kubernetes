locals {
  env = "dev"
}

# ---------------- Identity first ----------------
# Every host and every workload gets its own SA. Nothing is shared.
module "iam" {
  source = "../../modules/iam"

  project_id = var.project_id
  env        = local.env
}

# ---------------- Network ----------------
module "vpc" {
  source = "../../modules/vpc"

  project_id          = var.project_id
  region              = var.region
  env                 = local.env
  subnet_cidr         = "10.10.0.0/20"
  pods_cidr           = "10.11.0.0/16"
  services_cidr       = "10.12.0.0/20"
  master_cidr         = "172.16.0.0/28"
  tooling_subnet_cidr = "10.10.16.0/24"
}

# ---------------- Artifact Registry ----------------
module "artifact_registry" {
  source = "../../modules/artifact-registry"

  project_id = var.project_id
  region     = var.region
  env        = local.env

  # Only the build agent may push. Only the nodes may pull.
  #
  # These are MAPS, not lists. Terraform requires for_each KEYS to be known at
  # plan time, and these SA emails are not - they don't exist until apply.
  # A list would make the member string itself the key and fail with
  # "Invalid for_each argument". Static keys, apply-time values.
  writer_members = {
    "jenkins-agent" = "serviceAccount:${module.iam.jenkins_agent_sa_email}"
  }
  reader_members = {
    "gke-node" = "serviceAccount:${module.iam.gke_node_sa_email}"
  }
}

# ---------------- GKE: exactly 2 nodes ----------------
module "gke" {
  source = "../../modules/gke"

  project_id          = var.project_id
  region              = var.region
  env                 = local.env
  network             = module.vpc.network_name
  subnetwork          = module.vpc.gke_subnet_name
  pods_range_name     = module.vpc.pods_range_name
  services_range_name = module.vpc.services_range_name
  master_cidr         = "172.16.0.0/28"

  node_count           = var.node_count # 2
  machine_type         = var.machine_type
  node_disk_size_gb    = var.node_disk_size_gb
  node_disk_type       = var.disk_type
  node_service_account = module.iam.gke_node_sa_email

  authorized_cidrs = var.authorized_cidrs
}

# ---------------- Workload Identity per microservice ----------------
module "workload_identity" {
  source = "../../modules/workload-identity"

  project_id = var.project_id
  env        = local.env
  namespace  = local.env

  # Keys here are static literals, so for_each inside the module is safe.
  services = {
    "frontend"        = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
    ]
    "product-catalog" = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
    ]
    "cart"            = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
    ]
    "checkout"        = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
    ]
    "payment"         = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
      "roles/secretmanager.secretAccessor",
    ]
    "shipping"        = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
    ]
    "order"           = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
    ]
    "user-auth"       = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
      "roles/secretmanager.secretAccessor",
    ]
    "notification"    = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
      "roles/secretmanager.secretAccessor",
    ]
    "recommendation"  = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
    ]
  }

  depends_on = [module.gke]
}

# ---------------- Tooling hosts (separate VMs) ----------------
module "tooling" {
  source = "../../modules/tooling"

  project_id = var.project_id
  region     = var.region
  zone       = var.zone
  env        = local.env
  network    = module.vpc.network_name
  subnetwork = module.vpc.tooling_subnet_name

  bastion_sa_email            = module.iam.bastion_sa_email
  jenkins_controller_sa_email = module.iam.jenkins_controller_sa_email
  jenkins_agent_sa_email      = module.iam.jenkins_agent_sa_email
  sonarqube_sa_email          = module.iam.sonarqube_sa_email

  jenkins_controller_machine_type = var.jenkins_controller_machine_type
  jenkins_agent_machine_type      = var.jenkins_agent_machine_type
  sonarqube_machine_type          = var.sonarqube_machine_type

  disk_type                  = var.disk_type
  jenkins_controller_disk_gb = var.jenkins_controller_disk_gb
  jenkins_home_disk_gb       = var.jenkins_home_disk_gb
  jenkins_agent_disk_gb      = var.jenkins_agent_disk_gb
  sonarqube_disk_gb          = var.sonarqube_disk_gb
  sonar_data_disk_gb         = var.sonar_data_disk_gb
}
