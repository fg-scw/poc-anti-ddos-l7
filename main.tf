#####################################################################
# POC Anti-DDoS Layer 7 - HAProxy + CrowdSec + GeoIP
# Architecture: HAProxy HA → Scaleway LB → Backend Demo
# 
# Objectif: Valider la solution de protection L7 souveraine
#####################################################################

terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.45"
    }
  }
  required_version = ">= 1.0"
}

provider "scaleway" {
  zone       = var.zone
  region     = var.region
  project_id = var.project_id
}

#####################################################################
# DATA SOURCES
#####################################################################

data "scaleway_account_ssh_key" "main" {
  name = var.ssh_key_name
}

#####################################################################
# VPC & PRIVATE NETWORK
#####################################################################

resource "scaleway_vpc" "main" {
  name = "${var.project_name}-vpc"
  tags = var.tags
}

resource "scaleway_vpc_private_network" "main" {
  name   = "${var.project_name}-pn"
  vpc_id = scaleway_vpc.main.id
  tags   = var.tags

  ipv4_subnet {
    subnet = "10.0.1.0/24"
  }
}

#####################################################################
# PUBLIC GATEWAY - NAT pour les instances privées (backends)
#####################################################################

# IP publique pour la Public Gateway
resource "scaleway_vpc_public_gateway_ip" "main" {
  tags = var.tags
}

# Public Gateway avec NAT activé
resource "scaleway_vpc_public_gateway" "main" {
  name            = "${var.project_name}-pgw"
  type            = "VPC-GW-S" 
  ip_id           = scaleway_vpc_public_gateway_ip.main.id
  bastion_enabled = true
  tags            = var.tags
}

# Attachement du Private Network à la Public Gateway 
resource "scaleway_vpc_gateway_network" "main" {
  gateway_id         = scaleway_vpc_public_gateway.main.id
  private_network_id = scaleway_vpc_private_network.main.id
  enable_masquerade  = true  # Active le NAT (masquerade) pour l'accès internet
  
  # Configuration IPAM v2 - push la route par défaut via la gateway
  ipam_config {
    push_default_route = true
  }
}

#####################################################################
# SECURITY GROUPS
#####################################################################

# Security Group pour HAProxy (exposition publique)
resource "scaleway_instance_security_group" "haproxy" {
  name                    = "${var.project_name}-sg-haproxy"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  # SSH
  inbound_rule {
    action   = "accept"
    port     = 22
    protocol = "TCP"
  }

  # HTTP
  inbound_rule {
    action   = "accept"
    port     = 80
    protocol = "TCP"
  }

  # HTTPS
  inbound_rule {
    action   = "accept"
    port     = 443
    protocol = "TCP"
  }

  # HAProxy Stats
  inbound_rule {
    action   = "accept"
    port     = 8404
    protocol = "TCP"
  }

  # CrowdSec LAPI (internal only, mais ouvert pour le POC)
  inbound_rule {
    action   = "accept"
    port     = 8080
    protocol = "TCP"
  }

  # Prometheus metrics
  inbound_rule {
    action   = "accept"
    port     = 6060
    protocol = "TCP"
  }

  tags = var.tags
}

# Security Group pour les backends (accès privé uniquement)
resource "scaleway_instance_security_group" "backend" {
  name                    = "${var.project_name}-sg-backend"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  # SSH depuis HAProxy uniquement (via Private Network)
  inbound_rule {
    action   = "accept"
    port     = 22
    protocol = "TCP"
    ip_range = "10.0.1.0/24"
  }

  # HTTP depuis HAProxy/LB uniquement
  inbound_rule {
    action   = "accept"
    port     = 80
    protocol = "TCP"
    ip_range = "10.0.1.0/24"
  }

  # Health checks depuis LB
  inbound_rule {
    action   = "accept"
    port     = 80
    protocol = "TCP"
  }

  tags = var.tags
}

#####################################################################
# BACKEND DEMO INSTANCES 
#####################################################################

resource "scaleway_instance_server" "backend" {
  count = var.backend_instance_count

  name  = "${var.project_name}-backend-${count.index + 1}"
  type  = var.backend_instance_type
  image = "ubuntu_jammy"

  security_group_id = scaleway_instance_security_group.backend.id

  # Block Storage SBS - nouvelle syntaxe 2024+
  root_volume {
    volume_type           = "sbs_volume"
    sbs_iops              = var.sbs_iops
    size_in_gb            = 20
    delete_on_termination = true
  }

  private_network {
    pn_id = scaleway_vpc_private_network.main.id
  }

  user_data = {
    cloud-init = templatefile("${path.module}/scripts/cloud-init-backend.yaml", {
      backend_index = count.index + 1
    })
  }

  tags = concat(var.tags, ["backend", "nginx"])

  # Dépend de la Gateway Network pour avoir le NAT fonctionnel au boot
  depends_on = [
    scaleway_vpc_private_network.main,
    scaleway_vpc_gateway_network.main
  ]
}

#####################################################################
# IPAM DATA SOURCES - Récupération des IPs privées des backends
# Utilise le mac_address du bloc private_network
#####################################################################

data "scaleway_ipam_ip" "backend" {
  count = var.backend_instance_count

  mac_address        = scaleway_instance_server.backend[count.index].private_network[0].mac_address
  private_network_id = scaleway_vpc_private_network.main.id
  type               = "ipv4"
}

#####################################################################
# HAPROXY INSTANCES (créés après les backends)
#####################################################################

resource "scaleway_instance_ip" "haproxy" {
  count = var.haproxy_instance_count
  tags  = var.tags
}

resource "scaleway_instance_server" "haproxy" {
  count = var.haproxy_instance_count

  name  = "${var.project_name}-haproxy-${count.index + 1}"
  type  = var.haproxy_instance_type
  image = "ubuntu_jammy"

  ip_id             = scaleway_instance_ip.haproxy[count.index].id
  security_group_id = scaleway_instance_security_group.haproxy.id

  # Block Storage SBS - nouvelle syntaxe 2024+
  root_volume {
    volume_type           = "sbs_volume"
    sbs_iops              = var.sbs_iops
    size_in_gb            = 40
    delete_on_termination = true
  }

  private_network {
    pn_id = scaleway_vpc_private_network.main.id
  }

  # Cloud-init Production avec CrowdSec + GeoIP
  user_data = {
    cloud-init = templatefile("${path.module}/scripts/cloud-init-haproxy-production.yaml", {
      haproxy_index         = count.index + 1
      
      # CrowdSec configuration
      enable_crowdsec       = var.enable_crowdsec
      crowdsec_bouncer_key  = var.crowdsec_bouncer_key
      crowdsec_enroll_key   = var.crowdsec_enroll_key
      
      # GeoIP configuration
      enable_geoip          = var.enable_geoip
      geoip_license_key     = var.geoip_license_key
      enable_geoblocking    = var.enable_geoblocking
      allowed_countries     = var.allowed_countries
      
      # Backend IPs via IPAM
      backend_ips           = jsonencode([for ip in data.scaleway_ipam_ip.backend : ip.address])
      backend_count         = var.backend_instance_count
      
      # Rate limiting
      rate_limit_http       = var.rate_limit_http
      rate_limit_conn       = var.rate_limit_conn
      rate_limit_err        = var.rate_limit_err
      rate_limit_concurrent = var.rate_limit_concurrent
      
      # Cockpit monitoring
      enable_cockpit_monitoring = var.enable_cockpit_monitoring
      cockpit_metrics_url       = var.cockpit_metrics_url
      cockpit_logs_url          = var.cockpit_logs_url
      cockpit_token             = var.cockpit_token
    })
  }

  tags = concat(var.tags, ["haproxy", "crowdsec", "geoip"])

  # HAProxy dépend des backends et de leurs IPs IPAM
  depends_on = [
    scaleway_vpc_private_network.main,
    data.scaleway_ipam_ip.backend
  ]
}

#####################################################################
# IPAM DATA SOURCE - IP privée HAProxy (pour output)
#####################################################################

data "scaleway_ipam_ip" "haproxy" {
  count = var.haproxy_instance_count

  mac_address        = scaleway_instance_server.haproxy[count.index].private_network[0].mac_address
  private_network_id = scaleway_vpc_private_network.main.id
  type               = "ipv4"
}

#####################################################################
# SCALEWAY LOAD BALANCER - Architecture Production
# Internet → LB → HAProxy (private) → Backends (private)
#####################################################################

resource "scaleway_lb_ip" "main" {
  count = var.enable_scaleway_lb ? 1 : 0
  tags  = var.tags
}

resource "scaleway_lb" "main" {
  count = var.enable_scaleway_lb ? 1 : 0

  name  = "${var.project_name}-lb"
  ip_id = scaleway_lb_ip.main[0].id
  type  = var.lb_type

  # Attachement au Private Network (DHCP auto-configuré par IPAM)
  private_network {
    private_network_id = scaleway_vpc_private_network.main.id
  }

  tags = var.tags

  depends_on = [scaleway_vpc_gateway_network.main]
}

resource "scaleway_lb_backend" "haproxy" {
  count = var.enable_scaleway_lb ? 1 : 0

  name             = "haproxy-backend"
  lb_id            = scaleway_lb.main[0].id
  forward_port     = 80
  forward_protocol = "http"
  
  # PROXY PROTOCOL v2 pour transmettre l'IP réelle du client
  proxy_protocol = "v2"

  # Health check sur port dédié (sans proxy protocol)
  health_check_port = 8081
  health_check_http {
    uri = "/health"
  }

  health_check_timeout     = "5s"
  health_check_delay       = "10s"
  health_check_max_retries = 3

  # Timeouts pour protection contre Slow attacks (Slowloris, Slow Read)
  timeout_connect = "5s"
  timeout_server  = "10s"
  timeout_tunnel  = "10s"

  # Protection contre les connexions inactives
  on_marked_down_action = "shutdown_sessions"

  # IPs privées des HAProxy via IPAM - doit attendre que les IPs soient assignées
  server_ips = data.scaleway_ipam_ip.haproxy[*].address

  depends_on = [
    data.scaleway_ipam_ip.haproxy,
    scaleway_instance_server.haproxy
  ]
}

resource "scaleway_lb_frontend" "http" {
  count = var.enable_scaleway_lb ? 1 : 0

  name         = "http-frontend"
  lb_id        = scaleway_lb.main[0].id
  backend_id   = scaleway_lb_backend.haproxy[0].id
  inbound_port = 80

  # Timeout client pour protection Slowloris (ferme les connexions lentes)
  timeout_client = "10s"
}

resource "scaleway_lb_frontend" "https" {
  count = var.enable_scaleway_lb ? 1 : 0

  name         = "https-frontend"
  lb_id        = scaleway_lb.main[0].id
  backend_id   = scaleway_lb_backend.haproxy[0].id
  inbound_port = 443

  # Timeout client pour protection Slowloris
  timeout_client = "10s"
  
  # Note: Pour HTTPS avec certificat, ajouter:
  # certificate_ids = [scaleway_lb_certificate.main[0].id]
}

#####################################################################
# OUTPUTS
#####################################################################

output "haproxy_public_ips" {
  description = "Public IPs des instances HAProxy"
  value       = scaleway_instance_ip.haproxy[*].address
}

output "haproxy_private_ips" {
  description = "Private IPs des instances HAProxy (via IPAM)"
  value       = data.scaleway_ipam_ip.haproxy[*].address
}

output "backend_private_ips" {
  description = "Private IPs des backends (via IPAM)"
  value       = data.scaleway_ipam_ip.backend[*].address
}

output "public_gateway_ip" {
  description = "IP publique de la Public Gateway (NAT pour les backends)"
  value       = scaleway_vpc_public_gateway_ip.main.address
}

output "lb_public_ip" {
  description = "IP publique du Load Balancer Scaleway (si activé)"
  value       = var.enable_scaleway_lb ? scaleway_lb_ip.main[0].ip_address : null
}

output "haproxy_stats_urls" {
  description = "URLs des dashboards HAProxy Stats"
  value       = [for ip in scaleway_instance_ip.haproxy[*].address : "http://${ip}:8404/stats"]
}

output "test_endpoints" {
  description = "Endpoints pour tester le POC"
  value = {
    direct_haproxy_1  = "http://${scaleway_instance_ip.haproxy[0].address}"
    haproxy_stats     = "http://${scaleway_instance_ip.haproxy[0].address}:8404/stats"
    crowdsec_metrics  = "http://${scaleway_instance_ip.haproxy[0].address}:6060/metrics"
    via_lb            = var.enable_scaleway_lb ? "http://${scaleway_lb_ip.main[0].ip_address}" : "LB disabled"
  }
}

output "ssh_commands" {
  description = "Commandes SSH pour se connecter aux instances"
  value = {
    haproxy_1 = "ssh root@${scaleway_instance_ip.haproxy[0].address}"
    haproxy_2 = length(scaleway_instance_ip.haproxy) > 1 ? "ssh root@${scaleway_instance_ip.haproxy[1].address}" : "N/A"
  }
}

output "geoblocking_toggle_command" {
  description = "Commande pour activer/désactiver le géoblocage"
  value       = <<-EOT
    # Activer le géoblocage FR-only:
    ssh root@${scaleway_instance_ip.haproxy[0].address} 'sed -i "s/#use_backend bk_blocked_geo/use_backend bk_blocked_geo/" /etc/haproxy/haproxy.cfg && systemctl reload haproxy'
    
    # Désactiver le géoblocage:
    ssh root@${scaleway_instance_ip.haproxy[0].address} 'sed -i "s/use_backend bk_blocked_geo/#use_backend bk_blocked_geo/" /etc/haproxy/haproxy.cfg && systemctl reload haproxy'
  EOT
}

#####################################################################
# INJECTEURS DE CHARGE - DISTRIBUTED ATTACK SIMULATION
#####################################################################

# 1. Création d'un Security Group par zone
resource "scaleway_instance_security_group" "injector" {
  for_each = var.enable_injectors ? toset(var.injector_zones) : []
  
  name = "${var.project_name}-sg-injector-${each.key}"
  zone = each.key

  inbound_default_policy  = "accept"
  outbound_default_policy = "accept"
  
  inbound_rule {
    action   = "accept"
    port     = 22
    protocol = "TCP"
  }
}

# 2. Création des IPs Publiques dans les zones respectives
resource "scaleway_instance_ip" "injector" {
  count = var.enable_injectors ? var.injector_count : 0
  zone  = var.injector_zones[count.index % length(var.injector_zones)]
}

# 3. Création des serveurs d'injection
resource "scaleway_instance_server" "injector" {
  count = var.enable_injectors ? var.injector_count : 0
  
  # Sélection de la zone pour cette instance
  zone = var.injector_zones[count.index % length(var.injector_zones)]
  
  name  = "${var.project_name}-injector-${count.index + 1}"
  type  = "PLAY2-PICO"
  image = "ubuntu_jammy"

  # Assignation de l'IP créée dans la même zone
  ip_id = scaleway_instance_ip.injector[count.index].id
  
  # Assignation du Security Group de la zone correspondante
  security_group_id = scaleway_instance_security_group.injector[var.injector_zones[count.index % length(var.injector_zones)]].id

  user_data = {
    cloud-init = <<-EOT
      #cloud-config
      package_update: true
      packages:
        - gpg
        - curl
      runcmd:
        - curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
        - echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | tee /etc/apt/sources.list.d/k6.list
        - apt-get update
        - apt-get install k6 -y
        - echo "TARGET_URL='http://${var.enable_scaleway_lb ? scaleway_lb_ip.main[0].ip_address : ""}'" > /root/env.sh
    EOT
  }

  tags = concat(var.tags, ["injector", "k6"])
}

output "injector_ssh_commands" {
  description = "Commandes SSH pour se connecter aux injecteurs k6"
  value       = var.enable_injectors ? [for ip in scaleway_instance_ip.injector : "ssh root@${ip.address}"] : []
}