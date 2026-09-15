/* Mise en cache de l'app pour qu'elle s'ouvre sans réseau.
   Les données de l'utilisateur ne passent pas par ici : elles restent dans le
   stockage du navigateur. */

const CACHE = 'brio-v2';
const COQUILLE = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-512-maskable.png',
  './icons/apple-touch-icon.png',
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(COQUILLE)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(noms => Promise.all(noms.filter(n => n !== CACHE).map(n => caches.delete(n))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  // les appels aux autres domaines (Open Food Facts, CDN) ne sont jamais mis en cache
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;

  // La page elle-même est demandée sans repasser par le cache du navigateur.
  // Sans ça, « le réseau d'abord » ne suffit pas : l'hébergeur répond avec un
  // Cache-Control de dix minutes, le navigateur rend donc l'ancienne page sans
  // rien demander à personne, et on la remet en cache par-dessus. Une mise en
  // ligne mettait jusqu'à dix minutes à se voir ; elle arrive maintenant au
  // premier rechargement.
  const page = req.mode === 'navigate';
  const demande = page
    ? fetch(req.url, { cache: 'no-store', credentials: 'same-origin' })
    : fetch(req);

  // le réseau d'abord : une nouvelle version de l'app arrive dès qu'elle est en ligne,
  // et le cache ne sert que de filet quand la connexion manque
  e.respondWith(
    demande
      .then(rep => {
        const copie = rep.clone();
        caches.open(CACHE).then(c => c.put(req, copie));
        return rep;
      })
      .catch(() => caches.match(req).then(rep => rep || caches.match('./index.html')))
  );
});
