# Regional control plane (HA, replicated across zones) but a node pool
# pinned to exactly 2 nodes total, as required.
#
# NOTE on node_count vs zones: for a REGIONAL cluster, `node_count` in a
# node pool is PER ZONE. To get exactly 2 nodes we pin node_locations to a
# single zone and set node_count = 2. This keeps the control plane HA while
# honouring the hard 2-node limit.

resource "google_container_cluster" "primary" {
  name     = "${var.env}-gke"
  project  = var.project_id
  location = var.region

  # Pin nodes to one zone so 2 means 2.
  node_locations = ["${var.region}-a"]

  # We manage the node pool separately; remove the default one.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network
  subnetwork = var.subnetwork

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Private nodes: no public IPs. Control plane private, reached via bastion.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # keep public endpoint, but IP-restricted below
    master_ipv4_cidr_block  = var.master_cidr

    master_global_access_config {
      enabled = true
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  # Workload Identity: pods assume GCP SAs without any JSON key.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Dataplane V2 = eBPF/Cilium. Gives us NetworkPolicy enforcement natively.
  datapath_provider = "ADVANCED_DATAPATH"

  release_channel {
    channel = var.release_channel
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  addons_config {
    http_load_balancing { disabled = false }
    horizontal_pod_autoscaling { disabled = false }
    gcp_filestore_csi_driver_config { enabled = false }
  }

  maintenance_policy {
    recurring_window {
      start_time = "2025-01-01T18:30:00Z" # 00:00 IST
      end_time   = "2025-01-01T22:30:00Z" # 04:00 IST
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  # Guard against a stray `terraform destroy` on prod.
  deletion_protection = var.env == "prod" ? true : false

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

resource "google_container_node_pool" "primary" {
  name     = "${var.env}-pool"
  project  = var.project_id
  location = var.region
  cluster  = google_container_cluster.primary.name

  # PER ZONE. node_locations above is a single zone => 2 nodes total.
  node_count = var.node_count

  # Autoscaling deliberately NOT enabled: the 2-node count is a hard
  # requirement. In a real prod cluster you would enable it.

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.node_disk_size_gb
    disk_type    = var.node_disk_type
    image_type   = "COS_CONTAINERD"

    service_account = var.node_service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Hardening
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA" # required for Workload Identity
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    labels = {
      env  = var.env
      pool = "primary"
    }

    tags = ["gke-node", "${var.env}-gke-node"]
  }

  lifecycle {
    ignore_changes = [node_config[0].labels]
  }
}
