#####################################################################
# VARIABLES - POC Anti-DDoS Layer 7 (Production Ready)
#####################################################################

#####################################################################
# GENERAL
#####################################################################

variable "project_id" {
  description = "ID du projet Scaleway"
  type        = string
}

variable "project_name" {
  description = "Nom du projet (préfixe pour les ressources)"
  type        = string
  default     = "poc-ddos-l7-anct"
}

variable "region" {
  description = "Région Scaleway"
  type        = string
  default     = "fr-par"
}

variable "zone" {
  description = "Zone Scaleway"
  type        = string
  default     = "fr-par-1"
}

variable "tags" {
  description = "Tags à appliquer aux ressources"
  type        = list(string)
  default     = ["production", "ddos-l7", "anct", "terraform", "crowdsec"]
}

variable "ssh_key_name" {
  description = "Nom de la clé SSH dans Scaleway"
  type        = string
}

#####################################################################
# HAPROXY INSTANCES - HAUTE DISPONIBILITE
#####################################################################

variable "haproxy_instance_count" {
  description = "Nombre d'instances HAProxy (2 pour HA production)"
  type        = number
  default     = 2  # HA par défaut pour production
}

variable "haproxy_instance_type" {
  description = "Type d'instance pour HAProxy (gamme PLAY2)"
  type        = string
  default     = "PLAY2-MICRO" # 2 vCPU, 4GB RAM
  # Production haute charge: "PRO2-S" ou "PRO2-M"
}

#####################################################################
# BACKEND INSTANCES
#####################################################################

variable "backend_instance_count" {
  description = "Nombre d'instances backend demo"
  type        = number
  default     = 2
}

variable "backend_instance_type" {
  description = "Type d'instance pour les backends (gamme PLAY2)"
  type        = string
  default     = "PLAY2-PICO" # 1 vCPU, 2GB RAM
}

#####################################################################
# BLOCK STORAGE SBS
#####################################################################

variable "sbs_iops" {
  description = "IOPS pour les volumes Block Storage SBS (5000 ou 15000)"
  type        = number
  default     = 5000
  validation {
    condition     = contains([5000, 15000], var.sbs_iops)
    error_message = "sbs_iops doit être 5000 (sbs_5k) ou 15000 (sbs_15k)."
  }
}

#####################################################################
# SCALEWAY LOAD BALANCER
#####################################################################

variable "enable_scaleway_lb" {
  description = "Activer le Load Balancer Scaleway"
  type        = bool
  default     = true
}

variable "lb_type" {
  description = "Type de Load Balancer Scaleway"
  type        = string
  default     = "LB-S"
}

#####################################################################
# CROWDSEC CONFIGURATION
#####################################################################

variable "enable_crowdsec" {
  description = "Activer CrowdSec pour la threat intelligence"
  type        = bool
  default     = true  # Activé par défaut pour production
}

variable "crowdsec_bouncer_key" {
  description = "Clé API pour le bouncer CrowdSec (générée automatiquement si vide)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "crowdsec_enroll_key" {
  description = "Clé d'enrôlement CrowdSec Console (optionnel, pour dashboard centralisé)"
  type        = string
  default     = ""
  sensitive   = true
}

#####################################################################
# GEOIP CONFIGURATION
#####################################################################

variable "enable_geoip" {
  description = "Activer le filtrage GeoIP"
  type        = bool
  default     = true  # Activé par défaut pour souveraineté
}

variable "geoip_license_key" {
  description = "Clé de licence MaxMind GeoLite2 (gratuite, requiert inscription sur maxmind.com)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_geoblocking" {
  description = "Activer le géoblocage actif (bloque les pays non autorisés)"
  type        = bool
  default     = false  # Désactivé par défaut, mode monitoring d'abord
}

variable "allowed_countries" {
  description = "Liste des codes pays autorisés (ISO 3166-1 alpha-2)"
  type        = list(string)
  default     = [
    # Union Européenne
    "FR", "DE", "IT", "ES", "PT", "BE", "NL", "LU", "AT", "IE",
    "FI", "SE", "DK", "PL", "CZ", "SK", "HU", "RO", "BG", "HR",
    "SI", "EE", "LV", "LT", "CY", "MT", "GR",
    # EEE + Suisse
    "CH", "NO", "IS", "LI",
    # Territoires français
    "GP", "MQ", "GF", "RE", "YT", "PM", "BL", "MF", "WF", "PF", "NC"
  ]
}

#####################################################################
# RATE LIMITING CONFIGURATION
#####################################################################

variable "rate_limit_http" {
  description = "Nombre max de requêtes HTTP par IP sur 10 secondes"
  type        = number
  default     = 100
}

variable "rate_limit_conn" {
  description = "Nombre max de nouvelles connexions par IP sur 10 secondes"
  type        = number
  default     = 50
}

variable "rate_limit_err" {
  description = "Nombre max d'erreurs HTTP par IP sur 10 secondes (détection scan)"
  type        = number
  default     = 20
}

variable "rate_limit_concurrent" {
  description = "Nombre max de connexions simultanées par IP (anti-Slowloris)"
  type        = number
  default     = 20
}

#####################################################################
# SCALEWAY COCKPIT MONITORING
#####################################################################

variable "enable_cockpit_monitoring" {
  description = "Activer l'envoi de métriques et logs vers Scaleway Cockpit"
  type        = bool
  default     = false
}

variable "cockpit_metrics_url" {
  description = "URL de l'endpoint métriques Cockpit (format: https://xxx.metrics.cockpit.fr-par.scw.cloud)"
  type        = string
  default     = ""
}

variable "cockpit_logs_url" {
  description = "URL de l'endpoint logs Cockpit (format: https://xxx.logs.cockpit.fr-par.scw.cloud)"
  type        = string
  default     = ""
}

variable "cockpit_token" {
  description = "Token d'authentification Scaleway Cockpit (créer dans Console > Cockpit > Tokens)"
  type        = string
  default     = ""
  sensitive   = true
}

#####################################################################
# INJECTEURS DE CHARGE (DISTRIBUTED TESTING)
#####################################################################

variable "enable_injectors" {
  description = "Activer le déploiement des instances de test k6"
  type        = bool
  default     = false
}

variable "injector_count" {
  description = "Nombre total d'instances d'injection"
  type        = number
  default     = 3
}

variable "injector_zones" {
  description = "Liste des zones pour distribuer l'attaque"
  type        = list(string)
  default     = ["fr-par-1", "fr-par-2", "nl-ams-1"]
}