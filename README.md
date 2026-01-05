# POC Anti-DDoS Layer 7 - Scaleway

Solution souveraine de protection DDoS Layer 7 sur infrastructure Scaleway.

## Architecture

```
                     Internet
                         │
                         ▼
              ┌─────────────────────┐
              │   Scaleway LB       │  IP Publique
              │   Proxy Protocol v2 │  Timeouts anti-slow
              │   Health: :8081     │
              └──────────┬──────────┘
                         │
                   ┌─────┴─────┐
                   ▼           ▼
            ┌───────────┐ ┌───────────┐
            │ HAProxy 1 │ │ HAProxy 2 │   Haute Disponibilité
            │ CrowdSec  │ │ CrowdSec  │   Rate Limiting
            │ GeoIP     │ │ GeoIP     │   Threat Intelligence
            └─────┬─────┘ └─────┬─────┘
                  └──────┬──────┘
                         │
                   ┌─────┴─────┐
                   ▼           ▼
            ┌───────────┐ ┌───────────┐
            │ Backend 1 │ │ Backend 2 │   Application
            └───────────┘ └───────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │   Public Gateway    │   NAT + SSH Bastion
              └─────────────────────┘
```

## Protections

| Protection | Seuil | Description |
|------------|-------|-------------|
| HTTP Rate Limit | 100 req/10s | Limite requêtes par IP |
| Connection Rate | 50 conn/10s | Limite nouvelles connexions |
| Error Rate | 20 err/10s | Détection scanners |
| Concurrent Conn | 20 max | Anti-Slowloris |
| CrowdSec | - | Blocage IPs malveillantes |
| GeoIP | EU+DOM-TOM | Restriction géographique |

## Prérequis

- Compte Scaleway avec Project ID
- Clé SSH configurée dans Scaleway
- Terraform >= 1.0
- (Optionnel) Clé CrowdSec Console : https://app.crowdsec.net
- (Optionnel) Clé MaxMind GeoIP : https://www.maxmind.com/en/geolite2/signup

## Déploiement

```bash
# 1. Configurer
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars  # Renseigner project_id et ssh_key_name

# 2. Déployer
terraform init
terraform apply

# 3. Tester
./scripts/deploy-test-ddos.sh
```

## Configuration

### terraform.tfvars

```hcl
# Obligatoire
project_id   = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ssh_key_name = "my-ssh-key"

# Optionnel - CrowdSec
crowdsec_enroll_key = "xxxx"  # Console CrowdSec

# Optionnel - GeoIP
geoip_license_key = "xxxx"    # MaxMind
enable_geoblocking = true     # Activer le blocage
```

### Paramètres de Rate Limiting

```hcl
rate_limit_http       = 100  # Requêtes HTTP / 10s
rate_limit_conn       = 50   # Connexions / 10s
rate_limit_err        = 20   # Erreurs / 10s
rate_limit_concurrent = 20   # Connexions simultanées
```

## Test

```bash
# Script de test complet
./scripts/deploy-test-ddos.sh http://<LB_IP>

```

## Résultats Attendus

| Test | Résultat |
|------|----------|
| Trafic normal (10 req espacées) | 100% passent |
| HTTP Flood (500 req) | >80% bloqués (429) |
| Connexions simultanées (100) | >50% bloqués |
| Recovery (après 30s) | 100% passent |

## Fichiers

```
poc-ddos-l7/
├── main.tf                              # Infrastructure Terraform
├── variables.tf                         # Variables
├── terraform.tfvars.example             # Exemple de configuration
├── scripts/
│   ├── cloud-init-haproxy-production.yaml  # Config HAProxy + CrowdSec + GeoIP
│   ├── cloud-init-backend.yaml             # Config backends nginx
│   └── test.sh                             # Script de test
└── README.md
```