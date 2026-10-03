// Point d'entrée du serveur (npm start). Sans BACKUP_GITHUB_REPO / BACKUP_GITHUB_TOKEN :
// strictement équivalent à `node src/server.js`. Avec : restauration de la dernière sauvegarde
// AVANT d'ouvrir la base (db.js l'ouvre dès son require), puis sauvegardes automatiques (backup.js).
const { configFromEnv } = require('./backup');
const { log } = require('./logger');

const cfg = configFromEnv(process.env, log);

if (!cfg) {
  require('./server');
} else {
  main().catch((err) => {
    // Erreur au chargement du serveur : même comportement qu'avant (arrêt avec la pile d'appel).
    process.nextTick(() => {
      throw err;
    });
  });
}

async function main() {
  const { createBackup } = require('./backup');
  // Alerte visible dans l'app admin (monitor.js est chargé avec le serveur).
  const alert = (message) => {
    try {
      require('./monitor').raiseAlert('backup', 'critical', message, null, 60);
    } catch {}
  };
  const backup = createBackup(cfg, { log, alert });
  try {
    await backup.restore();
  } catch (err) {
    log.error(`sauvegarde : restauration interrompue : ${String(err.message).split(cfg.token).join('***')}`);
  }

  require('./server');
  backup.start();

  // Render envoie SIGTERM avant d'arrêter l'instance (≈ 30 s) : dernière sauvegarde puis sortie.
  let stopping = false;
  const onSignal = (signal) => {
    if (stopping) process.exit(1); // second signal : sortie immédiate
    stopping = true;
    log.info('arrêt demandé : dernière sauvegarde', { signal });
    backup
      .stop({ timeoutMs: 25000 })
      .then((r) => log.info('arrêt : sauvegarde terminée', { resultat: r?.pushed ? 'envoyée' : r?.error ? 'échec' : 'rien à envoyer' }))
      .catch(() => {})
      .finally(() => process.exit(0));
  };
  process.on('SIGTERM', onSignal);
  process.on('SIGINT', onSignal);
}
