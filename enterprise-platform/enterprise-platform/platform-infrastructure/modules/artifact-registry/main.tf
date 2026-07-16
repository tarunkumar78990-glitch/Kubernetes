resource "google_artifact_registry_repository" "docker" {
  provider      = google-beta
  project       = var.project_id
  location      = var.region
  repository_id = "${var.env}-${var.repo_name}"
  description   = "Docker images for ${var.env} microservices"
  format        = "DOCKER"

  docker_config {
    immutable_tags = var.env == "prod" ? true : false
  }

  # Automatic vulnerability scanning of pushed images.
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.keep_recent_count
    }
  }

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 days
    }
  }
}

# for_each over a MAP, not toset(list).
#
# toset() would make the member string itself the key - and that string holds
# an SA email that does not exist until apply. Terraform needs for_each KEYS
# at plan time. Static map keys fix it, and they also mean rotating the SA
# email updates the binding in place instead of destroying and recreating it.
resource "google_artifact_registry_repository_iam_member" "writers" {
  for_each   = var.writer_members
  provider   = google-beta
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each   = var.reader_members
  provider   = google-beta
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}
