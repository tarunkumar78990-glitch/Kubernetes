# For each microservice we create:
#   1. a GCP service account (GSA)
#   2. the project roles it genuinely needs
#   3. a binding letting the Kubernetes SA (KSA) impersonate the GSA
#
# The pod then gets GCP credentials with NO JSON key on disk.
# The KSA itself is created in the service's own k8s manifests with the
# annotation: iam.gke.io/gcp-service-account=<gsa email>

resource "google_service_account" "svc" {
  for_each = var.services

  project = var.project_id
  # account_id max 30 chars; env prefix + service name kept short.
  account_id   = substr("${var.env}-${each.key}", 0, 30)
  display_name = "Workload SA for ${each.key} (${var.env})"
}

# Flatten service -> roles into individual bindings.
locals {
  service_role_pairs = flatten([
    for svc, roles in var.services : [
      for role in roles : {
        svc  = svc
        role = role
      }
    ]
  ])
}

resource "google_project_iam_member" "svc_roles" {
  for_each = {
    for pair in local.service_role_pairs :
    "${pair.svc}-${pair.role}" => pair
  }

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.svc[each.value.svc].email}"
}

# The Workload Identity binding itself.
resource "google_service_account_iam_member" "wi_binding" {
  for_each = var.services

  service_account_id = google_service_account.svc[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${each.key}]"
}
