# Create an instance template with persistent disk for data storage
resource "google_compute_instance_template" "default" {
  name_prefix  = "${var.instance_name}-template-"
  machine_type = var.machine_type

  # Boot disk
  disk {
    auto_delete  = true
    boot         = true
    source_image = "projects/cos-cloud/global/images/cos-105-17412-535-63"
    disk_size_gb = 10
    disk_type    = "pd-standard"
    labels = {
      terraform_provisioned = "true"
    }
  }

  # Add a separate persistent disk for storing website hits data
  disk {
    auto_delete  = false
    boot         = false
    disk_type    = "pd-standard"
    disk_size_gb = 10
    device_name  = "data-disk"
  }


  can_ip_forward = false

  network_interface {
    network = "default"
    # No external IP needed for internal load balancing
  }

  metadata = {
    terraform_provisioned = "true"
  }

  # Startup script to mount data disk and set up application
  metadata_startup_script = <<EOF
    # Mount the persistent data disk if it's not already formatted
    DATA_DISK=/dev/disk/by-id/google-data-disk
    DATA_MOUNT=/mnt/data
    
    if [ ! -d $DATA_MOUNT ]; then
      mkdir -p $DATA_MOUNT
    fi
    
    if ! blkid $DATA_DISK; then
      mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard $DATA_DISK
    fi
    
    echo "$DATA_DISK $DATA_MOUNT ext4 discard,defaults 0 2" >> /etc/fstab
    mount -a
    
    # Create directory for website hits data
    mkdir -p $DATA_MOUNT/website_hits
    chmod 755 $DATA_MOUNT/website_hits
    
    echo "Persistent storage configured" > /test.txt
  EOF

  lifecycle {
    create_before_destroy = true
  }

  # Add service account with proper permissions to access Cloud SQL
  service_account {
    email  = var.service_account_email
    scopes = ["cloud-platform"]
  }

  # Required for load balancing health checks
  tags = ["allow-health-check", "allow-internal-lb"]
}

# Create a stateful regional managed instance group
resource "google_compute_region_instance_group_manager" "default" {
  name               = "${var.instance_name}-mig"
  base_instance_name = var.instance_name
  region             = var.region
  target_size        = var.instance_count
  
  version {
    instance_template = google_compute_instance_template.default.id
  }
  
  # Configure instances to be stateful so persistent disks remain attached
  stateful_disk {
    device_name = "data-disk"
    delete_rule = "NEVER"
  }
  
  # Configure named port that will be used by the load balancer
  named_port {
    name = "tcp-port"
    port = 80  # Your application port
  }
  
  # Configure update policy to ensure minimal disruption
  update_policy {
    type                  = "OPPORTUNISTIC"
    minimal_action        = "NONE"
    max_surge_fixed       = 3
    max_unavailable_fixed = 0
    replacement_method    = "SUBSTITUTE"
    instance_redistribution_type = "NONE"
  }

  
  # Add auto-healing with our TCP health check
  auto_healing_policies {
    health_check      = google_compute_health_check.default.id
    initial_delay_sec = 300
  }
}

# Create a health check for the load balancer
resource "google_compute_health_check" "default" {
  name                = "${var.instance_name}-health-check"
  check_interval_sec  = 30
  timeout_sec         = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3

  tcp_health_check {
    port = 22  # Using SSH port for TCP health check
  }
}

# Create firewall rule to allow health checks
resource "google_compute_firewall" "health_check" {
  name          = "allow-health-check"
  network       = "default"
  direction     = "INGRESS"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "10.0.0.0/8"]  # GCP health check IP ranges + internal IPs
  
  allow {
    protocol = "tcp"
    ports    = ["22"]  # Health check port
  }
  
  target_tags = ["allow-health-check"]
}

# Create firewall rule to allow traffic from internal sources
resource "google_compute_firewall" "internal_lb" {
  name          = "allow-internal-lb"
  network       = "default"
  direction     = "INGRESS"
  source_ranges = ["10.0.0.0/8"]  # Internal IP range
  
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]  # Your application ports
  }
  
  target_tags = ["allow-internal-lb"]
}

# Reserve an internal IP address for the load balancer
resource "google_compute_address" "internal" {
  name         = "${var.instance_name}-internal-address"
  subnetwork   = "default"  # Replace with your subnet if not using default
  address_type = "INTERNAL"
  region       = var.region
  purpose      = "SHARED_LOADBALANCER_VIP"
}

# Create a regional internal TCP load balancer
resource "google_compute_region_backend_service" "default" {
  name                  = "${var.instance_name}-backend"
  region                = var.region
  health_checks         = [google_compute_health_check.default.id]
  load_balancing_scheme = "INTERNAL"
  protocol              = "TCP"
  
  backend {
    group = google_compute_region_instance_group_manager.default.instance_group
    balancing_mode = "CONNECTION"
  }
}

# Create a forwarding rule for the internal load balancer
resource "google_compute_forwarding_rule" "default" {
  name                  = "${var.instance_name}-forwarding-rule"
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.default.id
  all_ports             = false
  ports                 = ["80"]
  network               = "default"
  subnetwork            = "default"  # Replace with your subnet if not using default
  ip_address            = google_compute_address.internal.address
}

# Create a Cloud SQL connection using Private Service Connect
resource "google_compute_global_address" "private_ip_address" {
  name          = "private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = "default"
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = "default"
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
  update_on_creation_fail = true
}

# Output the load balancer IP address
output "load_balancer_internal_ip" {
  description = "The internal IP address of the load balancer"
  value       = google_compute_address.internal.address
}

# Optional: Cloud DNS configuration for internal DNS
resource "google_dns_managed_zone" "private" {
  name        = "${var.instance_name}-private-zone"
  dns_name    = "${var.dns_domain}."
  description = "Private DNS zone for ${var.instance_name} application"
  
  visibility = "private"
  
  private_visibility_config {
    networks {
      network_url = "projects/${var.project_id}/global/networks/default"
    }
  }
}

resource "google_dns_record_set" "internal" {
  name         = "${var.instance_name}.${google_dns_managed_zone.private.dns_name}"
  managed_zone = google_dns_managed_zone.private.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.internal.address]
}

output "dns_name" {
    value = google_dns_record_set.internal.name  
}
