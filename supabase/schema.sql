-- Schéma de la base BRIO, à exécuter dans Supabase (SQL Editor).
-- Les données de l'app sont un simple stockage clé/valeur : une ligne par
-- donnée et par personne. C'est ce que l'app manipulait déjà côté navigateur.

create table if not exists public.donnees (
  user_id uuid not null references auth.users on delete cascade,
  cle     text not null,
  valeur  text not null,
  maj     timestamptz not null default now(),
  primary key (user_id, cle)
);

-- Sans cette ligne, la clé publique de l'app permettrait de lire les données
-- de tout le monde. Elle n'est pas optionnelle.
alter table public.donnees enable row level security;

create policy "lire ses donnees"      on public.donnees for select using (auth.uid() = user_id);
create policy "creer ses donnees"     on public.donnees for insert with check (auth.uid() = user_id);
create policy "modifier ses donnees"  on public.donnees for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "supprimer ses donnees" on public.donnees for delete using (auth.uid() = user_id);

-- Date de dernière modification, utile pour la synchronisation.
create or replace function public.touch_maj() returns trigger
  language plpgsql as $$ begin new.maj = now(); return new; end $$;

create trigger donnees_maj before update on public.donnees
  for each row execute function public.touch_maj();
