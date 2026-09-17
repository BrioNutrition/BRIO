// Relais d'analyse photo — fonction Supabase Edge.
//
// Le navigateur ne peut pas appeler l'API d'Anthropic directement : la clé y
// serait visible de tous. Cette fonction la garde côté serveur et se contente
// de transmettre la demande.
//
// Déploiement :
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-…
//   supabase functions deploy brio-photo
//
// Elle exige un utilisateur connecté (Supabase vérifie le jeton avant même
// d'entrer ici) : sans cela, n'importe qui pourrait s'en servir comme d'un
// accès gratuit à ton compte Anthropic.

const CLE = Deno.env.get('ANTHROPIC_API_KEY');

// On ne transmet que ce que l'app demande vraiment. Sans cette liste, le
// relais laisserait passer n'importe quel modèle et n'importe quelle longueur.
const MODELES = new Set(['claude-sonnet-4-6']);
const MAX_TOKENS = 1200;
const TAILLE_MAX = 6 * 1024 * 1024;   // une photo réduite pèse bien moins

const entetes = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
};

const refus = (message: string, code: number) =>
  new Response(JSON.stringify({ error: { message } }), { status: code, headers: entetes });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: entetes });
  if (req.method !== 'POST') return refus('Méthode non autorisée', 405);
  if (!CLE) return refus('Le relais n’a pas de clé d’API configurée', 500);

  const brut = await req.text();
  if (brut.length > TAILLE_MAX) return refus('Photo trop lourde', 413);

  let corps: Record<string, unknown>;
  try { corps = JSON.parse(brut); }
  catch { return refus('Demande illisible', 400); }

  if (!MODELES.has(String(corps.model))) return refus('Modèle non autorisé', 400);
  corps.max_tokens = Math.min(Number(corps.max_tokens) || MAX_TOKENS, MAX_TOKENS);

  let rep: Response;
  try {
    rep = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': CLE,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify(corps),
    });
  } catch {
    return refus('L’analyse est injoignable pour le moment', 502);
  }

  return new Response(await rep.text(), { status: rep.status, headers: entetes });
});
