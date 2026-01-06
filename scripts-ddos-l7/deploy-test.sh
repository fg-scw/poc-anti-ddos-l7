#!/bin/bash
# Orchestration du test DDoS distribué - POC ANCT

# Vérification de l'existence du fichier local
if [ ! -f "./test-ddos.js" ]; then
    echo "❌ Erreur: test-ddos.js est introuvable dans le dossier actuel."
    exit 1
fi

# Récupération des données Terraform
INJECTOR_IPS=$(terraform output -json injector_ssh_commands | jq -r '.[]' | sed 's/ssh root@//')
LB_IP=$(terraform output -raw lb_public_ip)

echo "--- Démarrage de l'orchestration ---"
echo "🎯 Cible (Load Balancer): $LB_IP"
echo "🤖 Injecteurs: $INJECTOR_IPS"

# 1. Attente du Cloud-Init sur les injecteurs
echo "⏳ Attente de la fin de l'installation sur les injecteurs (k6)..."
for IP in $INJECTOR_IPS; do
    until ssh -o StrictHostKeyChecking=no root@$IP "command -v k6" &>/dev/null; do
        echo "  [...] k6 n'est pas encore prêt sur $IP, attente 5s..."
        sleep 5
    done
    echo "  ✅ Injecteur $IP est prêt."
done

# 2. Déploiement du script
for IP in $INJECTOR_IPS; do
    echo "📤 Envoi du script k6 vers $IP..."
    scp -o StrictHostKeyChecking=no ./test-ddos.js root@$IP:/root/test-ddos.js
done

# 3. Lancement de l'attaque distribuée
echo "🔥 Lancement de l'attaque distribuée (3 IPs sources)..."
for IP in $INJECTOR_IPS; do
    ssh -o StrictHostKeyChecking=no root@$IP "k6 run -e TARGET_URL=http://$LB_IP /root/test-ddos.js" &
done

echo "📊 Attaque en cours."
echo "👉 Vérifiez HAProxy : watch \"echo 'show table fe_main' | socat stdio /run/haproxy/admin.sock\""
wait