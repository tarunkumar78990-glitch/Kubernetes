output "bastion_name" {
  value = google_compute_instance.bastion.name
}

output "bastion_internal_ip" {
  value = google_compute_instance.bastion.network_interface[0].network_ip
}

output "jenkins_controller_name" {
  value = google_compute_instance.jenkins_controller.name
}

output "jenkins_controller_internal_ip" {
  value = google_compute_instance.jenkins_controller.network_interface[0].network_ip
}

output "jenkins_agent_name" {
  value = google_compute_instance.jenkins_agent.name
}

output "jenkins_agent_internal_ip" {
  value = google_compute_instance.jenkins_agent.network_interface[0].network_ip
}

output "sonarqube_name" {
  value = google_compute_instance.sonarqube.name
}

output "sonarqube_internal_ip" {
  value = google_compute_instance.sonarqube.network_interface[0].network_ip
}
