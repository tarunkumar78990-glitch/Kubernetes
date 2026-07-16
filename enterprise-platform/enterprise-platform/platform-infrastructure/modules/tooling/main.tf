# Four separate hosts. This is the enterprise separation:
#   bastion            - only entry point, tiny, no tools
#   jenkins-controller - orchestration + credentials. NEVER builds.
#   jenkins-agent      - Docker builds, tests, Trivy, kubectl. Untrusted code runs here.
#   sonarqube          - stateful scanner + its Postgres DB, own disk
#
# Only the bastion is reachable from outside, and only via IAP.

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

# ---------------- Bastion ----------------
resource "google_compute_instance" "bastion" {
  name         = "${var.env}-bastion"
  project      = var.project_id
  zone         = var.zone
  machine_type = var.bastion_machine_type

  tags = ["ssh-allowed", "bastion"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork
    # No access_config block => NO public IP. Reached only via IAP tunnel.
  }

  service_account {
    email  = var.bastion_sa_email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = file("${path.module}/scripts/bastion-startup.sh")

  allow_stopping_for_update = true

  labels = {
    env  = var.env
    role = "bastion"
  }
}

# ---------------- Jenkins controller ----------------
resource "google_compute_instance" "jenkins_controller" {
  name         = "${var.env}-jenkins-controller"
  project      = var.project_id
  zone         = var.zone
  machine_type = var.jenkins_controller_machine_type

  tags = ["ssh-allowed", "jenkins-controller"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.jenkins_controller_disk_gb
      type  = var.disk_type
    }
  }

  # Jenkins home on a separate disk so the VM can be rebuilt without data loss.
  attached_disk {
    source      = google_compute_disk.jenkins_home.id
    device_name = "jenkins-home"
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork
  }

  service_account {
    email  = var.jenkins_controller_sa_email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = file("${path.module}/scripts/jenkins-controller-startup.sh")

  allow_stopping_for_update = true

  labels = {
    env  = var.env
    role = "jenkins-controller"
  }
}

resource "google_compute_disk" "jenkins_home" {
  name    = "${var.env}-jenkins-home"
  project = var.project_id
  zone    = var.zone
  size    = var.jenkins_home_disk_gb
  type    = var.disk_type
}

# ---------------- Jenkins agent ----------------
resource "google_compute_instance" "jenkins_agent" {
  name         = "${var.env}-jenkins-agent-01"
  project      = var.project_id
  zone         = var.zone
  machine_type = var.jenkins_agent_machine_type

  tags = ["ssh-allowed", "jenkins-agent"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.jenkins_agent_disk_gb
      type  = var.disk_type
    }
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork
  }

  service_account {
    email  = var.jenkins_agent_sa_email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = file("${path.module}/scripts/jenkins-agent-startup.sh")

  allow_stopping_for_update = true

  labels = {
    env  = var.env
    role = "jenkins-agent"
  }
}

# ---------------- SonarQube ----------------
resource "google_compute_instance" "sonarqube" {
  name         = "${var.env}-sonarqube"
  project      = var.project_id
  zone         = var.zone
  machine_type = var.sonarqube_machine_type

  tags = ["ssh-allowed", "sonarqube"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.sonarqube_disk_gb
      type  = var.disk_type
    }
  }

  attached_disk {
    source      = google_compute_disk.sonar_data.id
    device_name = "sonar-data"
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork
  }

  service_account {
    email  = var.sonarqube_sa_email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = file("${path.module}/scripts/sonarqube-startup.sh")

  allow_stopping_for_update = true

  labels = {
    env  = var.env
    role = "sonarqube"
  }
}

resource "google_compute_disk" "sonar_data" {
  name    = "${var.env}-sonar-data"
  project = var.project_id
  zone    = var.zone
  size    = var.sonar_data_disk_gb
  type    = var.disk_type
}
