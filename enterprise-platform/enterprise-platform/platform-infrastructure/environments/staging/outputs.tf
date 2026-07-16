output "cluster_name" {
  value = module.gke.cluster_name
}

output "cluster_location" {
  value = module.gke.cluster_location
}

output "artifact_registry_url" {
  value = module.artifact_registry.repository_url
}

output "workload_identity_service_accounts" {
  description = "Paste each into the matching service's KSA annotation."
  value       = module.workload_identity.service_account_emails
}

output "jenkins_controller_ip" {
  value = module.tooling.jenkins_controller_internal_ip
}

output "jenkins_agent_ip" {
  value = module.tooling.jenkins_agent_internal_ip
}

output "sonarqube_ip" {
  value = module.tooling.sonarqube_internal_ip
}

output "bastion_name" {
  value = module.tooling.bastion_name
}

output "kubectl_connect_command" {
  value = "gcloud container clusters get-credentials ${module.gke.cluster_name} --region ${module.gke.cluster_location} --project ${var.project_id}"
}
