import http from 'k6/http';
import { check, sleep } from 'k6';
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';
import exec from 'k6/execution';

// Configuration de la cible via variable d'environnement
const TARGET_URL = __ENV.TARGET_URL || 'http://votre-ip-lb';

export const options = {
  scenarios: {
    // 1. TRAFIC LÉGITIME : Simule des utilisateurs réels (5 requêtes par seconde)
    legitimate_traffic: {
      executor: 'constant-arrival-rate',
      rate: 5, 
      timeUnit: '1s',
      duration: '2m',
      preAllocatedVUs: 2,
      maxVUs: 10,
    },
    // 2. HTTP FLOOD : Monte en puissance pour dépasser le seuil de 100 req/10s 
    http_flood: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      stages: [
        { target: 15, duration: '30s' }, // Sous le seuil de blocage
        { target: 60, duration: '30s' }, // Pic à 600 req/10s (doit être bloqué) 
        { target: 10, duration: '30s' }, // Retour au calme
      ],
      preAllocatedVUs: 50,
      maxVUs: 100,
      startTime: '30s',
    },
    // 3. ERROR SCAN : Génère des 404 pour trigger le seuil d'erreurs (20 err/10s) 
    error_scan: {
      executor: 'per-vu-iterations',
      vus: 5,
      iterations: 40,
      startTime: '60s',
    },
  },
  thresholds: {
    // On s'attend à ce que le scénario flood soit majoritairement bloqué (429)
    'http_req_failed{scenario:http_flood}': ['rate>0.5'],
    // On s'attend à un blocage quasi total du scanner d'erreurs
    'http_req_failed{scenario:error_scan}': ['rate>0.8'],
  },
};

const userAgents = [
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  'Mozilla/5.0 (iPhone; CPU iPhone OS 14_7_1 like Mac OS X)',
  'Googlebot/2.1 (+http://www.google.com/bot.html)',
  'curl/7.68.0',
];

export default function () {
  const scenarioName = exec.scenario.name;
  
  const params = {
    headers: {
      'User-Agent': userAgents[Math.floor(Math.random() * userAgents.length)],
      'X-App-Test': 'Anti-DDoS-POC',
    },
  };

  // LOGIQUE PAR SCÉNARIO
  if (scenarioName === 'error_scan') {
    // Chemins typiques de scanners de vulnérabilités
    const badPaths = ['/.env', '/wp-login.php', '/config.php', '/admin/setup', '/.git/config'];
    const res = http.get(`${TARGET_URL}${badPaths[randomIntBetween(0, 4)]}`, params);
    
    // Vérifie si HAProxy a renvoyé un 429 (Rate Limit) ou un 403 (CrowdSec/GeoIP) 
    check(res, { 'blocked (429/403)': (r) => r.status === 429 || r.status === 403 });
    
  } else if (scenarioName === 'http_flood') {
    // Flood sur la page d'accueil avec cache-busting
    const res = http.get(`${TARGET_URL}/?attack_id=${Math.random()}`, params);
    check(res, { 'flood blocked (429)': (r) => r.status === 429 });
    
  } else {
    // Trafic normal (doit rester en 200 OK)
    const res = http.get(`${TARGET_URL}/`, params);
    check(res, { 'legit success (200)': (r) => r.status === 200 });
  }

  // Temps de réflexion aléatoire entre les itérations
  sleep(Math.random() * 0.5);
}