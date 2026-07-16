output "gke_node_sa_email" {
  value = google_service_account.gke_node.email
}

output "jenkins_controller_sa_email" {
  value = google_service_account.jenkins_controller.email
}

output "jenkins_agent_sa_email" {
  value = google_service_account.jenkins_agent.email
}

output "sonarqube_sa_email" {
  value = google_service_account.sonarqube.email
}

output "bastion_sa_email" {
  value = google_service_account.bastion.email
}
