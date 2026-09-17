-- Stories BRIO : partager une photo du jour et un mot, rien d'autre.
-- À exécuter dans Supabase (SQL Editor), après schema.sql.
--
-- Règle de conception, et elle n'est pas négociable : ce fichier ne touche
-- jamais à la table « donnees ». Le journal — repas, poids, eau, objectifs —
-- garde sa règle absolue : chacun ne lit que ses propres lignes. Les amis ne
-- voient qu'une photo et un mot, jamais un chiffre.

-- ---------------------------------------------------------------- profils --
-- Le strict minimum rendu visible : un pseudo pour être trouvé, un avatar.
create table if not exists public.profils (
  user_id uuid primary key references auth.users on delete cascade,
  pseudo  text not null unique
    check (pseudo ~ '^[a-zA-Z0-9_]{3,20}$'),
  avatar  text,
  maj     timestamptz not null default now()
);

-- ----------------------------------------------------------------- amitié --
-- Une seule ligne par paire, quel que soit le sens de la demande : « petit »
-- et « grand » sont les deux identifiants triés. Sans cela, A→B et B→A
-- pourraient coexister et se contredire.
create table if not exists public.amities (
  petit     uuid not null references auth.users on delete cascade,
  grand     uuid not null references auth.users on delete cascade,
  demandeur uuid not null references auth.users on delete cascade,
  etat      text not null default 'en_attente'
    check (etat in ('en_attente','acceptee','bloquee')),
  cree      timestamptz not null default now(),
  primary key (petit, grand),
  check (petit < grand)
);

-- ---------------------------------------------------------------- stories --
-- La ligne ne garde que le chemin du fichier, jamais l'image elle-même.
create table if not exists public.stories (
  id     uuid primary key default gen_random_uuid(),
  auteur uuid not null references auth.users on delete cascade,
  chemin text not null,
  mot    text check (mot is null or char_length(mot) <= 140),
  cree   timestamptz not null default now(),
  expire timestamptz not null default now() + interval '24 hours'
);
create index if not exists stories_auteur_expire on public.stories (auteur, expire desc);

-- -------------------------------------------------------------- réactions --
-- La liste fermée est ici, et pas seulement dans les boutons de l'app : sinon
-- n'importe qui peut envoyer n'importe quel texte directement à l'API.
create table if not exists public.reactions (
  story_id uuid not null references public.stories on delete cascade,
  auteur   uuid not null references auth.users on delete cascade,
  emoji    text not null check (emoji in ('👏','🔥','😍','💪','😋','🙌')),
  cree     timestamptz not null default now(),
  primary key (story_id, auteur)
);

-- ------------------------------------------------------- « sont-ils amis » --
-- En « security definer » pour une raison précise : si la règle de stories
-- interrogeait amities, dont la règle interroge amities, Postgres partirait en
-- récursion infinie. La fonction casse la boucle en contournant les règles —
-- elle ne renvoie qu'un booléen, elle ne laisse rien filtrer.
create or replace function public.est_ami(autre uuid) returns boolean
  language sql security definer stable
  set search_path = public
as $$
  select exists (
    select 1 from public.amities
    where etat = 'acceptee'
      and petit = least(auth.uid(), autre)
      and grand = greatest(auth.uid(), autre)
  )
$$;

-- --------------------------------------------------------------- les règles --
alter table public.profils   enable row level security;
alter table public.amities   enable row level security;
alter table public.stories   enable row level security;
alter table public.reactions enable row level security;

-- Profils : lisibles de tous (c'est ce qui permet de chercher un pseudo),
-- modifiables par leur seul propriétaire.
drop policy if exists "profils lisibles" on public.profils;
create policy "profils lisibles" on public.profils for select using (true);
drop policy if exists "son profil : creer" on public.profils;
create policy "son profil : creer" on public.profils for insert with check (auth.uid() = user_id);
drop policy if exists "son profil : modifier" on public.profils;
create policy "son profil : modifier" on public.profils for update
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Amitiés : on ne voit que les siennes.
drop policy if exists "ses amities" on public.amities;
create policy "ses amities" on public.amities for select
  using (auth.uid() in (petit, grand));
-- Demander : on doit être dans la paire, être soi-même le demandeur, et la
-- demande doit naître « en attente ». Sans cette dernière condition, n'importe
-- qui s'insère une amitié déjà acceptée et lit les stories de sa cible.
drop policy if exists "demander" on public.amities;
create policy "demander" on public.amities for insert
  with check (auth.uid() in (petit, grand)
    and auth.uid() = demandeur
    and etat = 'en_attente');
-- Répondre : seul celui qui n'a pas demandé peut accepter ou bloquer. Le
-- « with check » répète la condition sur la ligne d'arrivée, sinon on pourrait
-- se réécrire demandeur au passage et s'accepter soi-même.
drop policy if exists "repondre" on public.amities;
create policy "repondre" on public.amities for update
  using (auth.uid() in (petit, grand) and auth.uid() <> demandeur)
  with check (auth.uid() in (petit, grand) and auth.uid() <> demandeur);
drop policy if exists "retirer" on public.amities;
create policy "retirer" on public.amities for delete using (auth.uid() in (petit, grand));

-- Stories : les siennes, et celles des amis tant qu'elles n'ont pas expiré.
drop policy if exists "ses stories et celles des amis" on public.stories;
create policy "ses stories et celles des amis" on public.stories for select
  using (auteur = auth.uid() or (expire > now() and public.est_ami(auteur)));
drop policy if exists "poser sa story" on public.stories;
create policy "poser sa story" on public.stories for insert with check (auteur = auth.uid());
drop policy if exists "retirer sa story" on public.stories;
create policy "retirer sa story" on public.stories for delete using (auteur = auth.uid());

-- Réactions : visibles par ceux qui voient la story ; on ne pose que la sienne.
drop policy if exists "reactions visibles" on public.reactions;
create policy "reactions visibles" on public.reactions for select
  using (exists (select 1 from public.stories s where s.id = story_id));
drop policy if exists "reagir" on public.reactions;
create policy "reagir" on public.reactions for insert
  with check (auteur = auth.uid()
    and exists (select 1 from public.stories s where s.id = story_id));
drop policy if exists "changer sa reaction" on public.reactions;
create policy "changer sa reaction" on public.reactions for update
  using (auteur = auth.uid()) with check (auteur = auth.uid());
drop policy if exists "retirer sa reaction" on public.reactions;
create policy "retirer sa reaction" on public.reactions for delete using (auteur = auth.uid());

-- ------------------------------------------------------ les photos (bucket) --
-- La base ne garde jamais l'image : seulement son chemin. Le fichier vit dans
-- un bucket privé, sous « <user_id>/<quelque chose>.jpg ». Le premier dossier
-- porte l'identifiant du propriétaire : c'est ce qui permet aux règles de
-- décider sans interroger la table des stories.
insert into storage.buckets (id, name, public)
  values ('stories', 'stories', false)
  on conflict (id) do nothing;

-- Déposer, remplacer et retirer : uniquement dans son propre dossier.
drop policy if exists "deposer sa photo" on storage.objects;
create policy "deposer sa photo" on storage.objects for insert
  with check (bucket_id = 'stories' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "retirer sa photo" on storage.objects;
create policy "retirer sa photo" on storage.objects for delete
  using (bucket_id = 'stories' and (storage.foldername(name))[1] = auth.uid()::text);

-- Lire : la sienne, ou celle d'un ami dont la story n'a pas expiré. La
-- condition reprend exactement celle de la table, pour qu'une photo ne survive
-- pas à la story qui la portait.
drop policy if exists "voir la photo d une story visible" on storage.objects;
create policy "voir la photo d une story visible" on storage.objects for select
  using (bucket_id = 'stories' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (
      select 1 from public.stories s
      where s.chemin = storage.objects.name
        and s.expire > now()
        and public.est_ami(s.auteur)
    )
  ));

-- ------------------------------------------------- effacer au bout de 24 h --
-- Deux moitiés, et on n'en fait souvent qu'une. La règle de lecture *cache*
-- les stories expirées ; elle n'efface rien. Sans le ménage ci-dessous, les
-- lignes et surtout les fichiers s'accumulent indéfiniment.
create or replace function public.menage_stories() returns integer
  language plpgsql security definer
  set search_path = public
as $$
declare n integer;
begin
  -- les fichiers d'abord : une fois la ligne partie, on ne sait plus quoi effacer
  delete from storage.objects
   where bucket_id = 'stories'
     and name in (select chemin from public.stories where expire <= now());
  delete from public.stories where expire <= now();
  get diagnostics n = row_count;
  return n;
end $$;

-- À programmer une fois, dans Supabase (extension pg_cron activée) :
--   select cron.schedule('menage-stories', '17 * * * *', 'select public.menage_stories()');
-- Toutes les heures à la minute 17 plutôt qu'à l'heure pile : les tâches
-- planifiées se bousculent toutes à zéro.

-- ---------------------------------------------------------- temps réel --
-- Sans cette publication, Supabase n'envoie rien : l'app ne saurait qu'une
-- story est arrivée qu'en redemandant. Les règles d'accès s'appliquent aussi
-- au temps réel — on ne reçoit que ce qu'on a le droit de lire.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.stories;   exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.amities;   exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.reactions; exception when duplicate_object then null; end;
  end if;
end $$;

-- Sans « replica identity full », une suppression n'annonce que la clé ; avec,
-- l'app sait quelle story a disparu.
alter table public.stories   replica identity full;
alter table public.amities   replica identity full;
alter table public.reactions replica identity full;

-- ------------------------------------------------------------- contrôle --
-- Dernière ligne du fichier, volontairement : si elle ne s'affiche pas, c'est
-- que le collage a été tronqué en route et que tout n'a pas été exécuté.
-- Attendu : « stories : 4 tables, 17 règles, 3 en temps réel ».
select 'stories : '
  || (select count(*) from pg_tables
        where schemaname = 'public'
          and tablename in ('profils','amities','stories','reactions'))
  || ' tables, '
  || (select count(*) from pg_policies
        where (schemaname = 'public'
               and tablename in ('profils','amities','stories','reactions'))
           or schemaname = 'storage')
  || ' règles, '
  || (select count(*) from pg_publication_tables
        where pubname = 'supabase_realtime'
          and tablename in ('stories','amities','reactions'))
  || ' en temps réel' as controle;
