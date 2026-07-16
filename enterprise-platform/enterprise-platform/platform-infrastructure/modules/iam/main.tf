# One service account per host / role. Least privilege, no shared identity.
# This is the core of "each host has its own identity" in an enterprise setup.

# --- GKE nodes ---
resource "google_service_account" "gke_node" {
  project      = var.project_id
  account_id   = "${var.env}-gke-node"
  display_name = "GKE node SA (${var.env})"
}

# Minimum roles a node needs. Deliberately NOT roles/editor.
locals {
  gke_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ]

  jenkins_agent_roles = [
    # The agent deploys, so it needs container.developer. The CONTROLLER
    # deliberately does not - see jenkins_controller_roles above.
    #
    # PART 6 (GitOps) DELETES THE LINE BELOW. Once Argo CD pulls from Git,
    # Jenkins never touches the cluster and this role becomes an unused
    # liability. `terraform plan` will then show "1 to destroy" - that is the
    # GitOps security dividend, visible in a plan output.
    "roles/container.developer",       # deploy to GKE, not admin it
    "roles/artifactregistry.writer",   # push images
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]

  jenkins_controller_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    # Deliberately cannot deploy or push. Orchestration only.
  ]

  sonarqube_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]

  bastion_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]
}

resource "google_project_iam_member" "gke_node" {
  for_each = toset(local.gke_node_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.gke_node.email}"
}

# --- Jenkins controller ---
resource "google_service_account" "jenkins_controller" {
  project      = var.project_id
  account_id   = "${var.env}-jenkins-controller"
  display_name = "Jenkins controller SA (${var.env})"
}

resource "google_project_iam_member" "jenkins_controller" {
  for_each = toset(local.jenkins_controller_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.jenkins_controller.email}"
}

# --- Jenkins agent (the one that actually builds and deploys) ---
resource "google_service_account" "jenkins_agent" {
  project      = var.project_id
  account_id   = "${var.env}-jenkins-agent"
  display_name = "Jenkins build agent SA (${var.env})"
}

resource "google_project_iam_member" "jenkins_agent" {
  for_each = toset(local.jenkins_agent_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.jenkins_agent.email}"
}

# --- SonarQube ---
resource "google_service_account" "sonarqube" {
  project      = var.project_id
  account_id   = "${var.env}-sonarqube"
  display_name = "SonarQube SA (${var.env})"
}

resource "google_project_iam_member" "sonarqube" {
  for_each = toset(local.sonarqube_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.sonarqube.email}"
}

# --- Bastion ---
resource "google_service_account" "bastion" {
  project      = var.project_id
  account_id   = "${var.env}-bastion"
  display_name = "Bastion SA (${var.env})"
}

resource "google_project_iam_member" "bastion" {
  for_each = toset(local.bastion_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.bastion.email}"
}
