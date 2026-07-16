# Custom-mode VPC. Enterprises never use the auto-mode "default" network:
# it creates a subnet in every region with permissive defaults.

resource "google_compute_network" "vpc" {
  name                            = "${var.env}-vpc"
  project                         = var.project_id
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false
}

# Subnet for GKE nodes, with secondary ranges for VPC-native (alias IP) networking.
resource "google_compute_subnetwork" "gke" {
  name                     = "${var.env}-gke-subnet"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${var.env}-pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "${var.env}-services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Separate subnet for the tooling VMs (Jenkins, Sonar, bastion).
resource "google_compute_subnetwork" "tooling" {
  name                     = "${var.env}-tooling-subnet"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.tooling_subnet_cidr
  private_ip_google_access = true
}

# Cloud Router + NAT: private nodes and private VMs have no public IP,
# but still need egress to pull base images and reach APIs.
resource "google_compute_router" "router" {
  name    = "${var.env}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.env}-nat"
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---- Firewall ----

# SSH only from Google's IAP range. No 0.0.0.0/0 SSH, ever.
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.env}-allow-iap-ssh"
  project = var.project_id
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  # 35.235.240.0/20 is the fixed range Identity-Aware Proxy tunnels from.
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["ssh-allowed"]
}

# IAP can also forward arbitrary TCP ports (`gcloud compute start-iap-tunnel`),
# not just 22. Jenkins (8080) and SonarQube (9000) have no public IP by
# design, so this rule is the ONLY path to their UIs.
#
# THIS WAS MISSING in earlier versions of this module. Without it, every
# `start-iap-tunnel` to 8080/9000 connects (the tunnel itself only needs SSH
# to establish) but the HTTP request inside it times out - the packet reaches
# the VM's NIC and is dropped before it ever hits the process. It looks
# exactly like a hung server. It is actually a silent firewall drop.
resource "google_compute_firewall" "allow_iap_web" {
  name        = "${var.env}-allow-iap-web"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "IAP TCP tunnel access to Jenkins (8080) and SonarQube (9000), which have no public IP."

  allow {
    protocol = "tcp"
    ports    = ["8080", "9000"]
  }
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["jenkins-controller", "sonarqube"]
}

# Internal traffic between tooling hosts.
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.env}-allow-internal"
  project = var.project_id
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow { protocol = "icmp" }

  source_ranges = [var.subnet_cidr, var.tooling_subnet_cidr]
}

# GKE control plane -> webhooks/metrics on nodes.
resource "google_compute_firewall" "allow_master_webhook" {
  name    = "${var.env}-allow-master-webhook"
  project = var.project_id
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8443", "9443", "15017", "10250"]
  }
  source_ranges = [var.master_cidr]
  target_tags   = ["gke-node"]
}

resource "google_compute_firewall" "deny_all_ingress" {
  name     = "${var.env}-deny-all-ingress"
  project  = var.project_id
  network  = google_compute_network.vpc.name
  priority = 65534
  direction = "INGRESS"

  deny { protocol = "all" }
  source_ranges = ["0.0.0.0/0"]
}
