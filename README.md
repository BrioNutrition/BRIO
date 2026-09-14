# BRIO

Application web de suivi nutritionnel : journal des repas, hydratation, suivi du
poids et recettes, avec la mascotte Brioche.

L'application tient dans un seul fichier `index.html` (HTML, CSS et JavaScript
inclus, polices et images intégrées). Aucune installation ni dépendance :
il suffit d'ouvrir le fichier dans un navigateur.

## Les comptes et les données

En ligne, chaque personne a un compte et retrouve son suivi sur tous ses
appareils. Les comptes et les données sont gérés par Supabase ; le schéma de la
base et les règles d'accès sont dans `supabase/schema.sql`.

Chacun ne peut lire et écrire que ses propres données : c'est garanti par les
règles RLS de Supabase, côté serveur. La clé présente dans `index.html` est la
clé publique du projet, prévue pour être visible dans une app web.

Le stockage du navigateur reste utilisé comme cache : l'app s'ouvre et répond
sans réseau, et les modifications faites hors connexion repartent au retour du
réseau.

En cas de mot de passe oublié, Supabase envoie un lien qui ramène sur l'app pour
en choisir un nouveau. Ce retour suppose que l'adresse du site soit renseignée
dans Supabase, sous *Authentication → URL Configuration*.

Les e-mails envoyés aux utilisateurs sont dans `supabase/emails/`. Ce sont des
copies de référence : Supabase garde les siennes, à coller sous *Authentication
→ Emails → Templates*. Le lien qu'ils contiennent ne doit pas être remplacé,
l'app ne reconnaît que les formes décrites en tête de chaque fichier.

Ouvert depuis un aperçu Claude plutôt qu'en ligne, l'app bascule seule sur un
stockage local, sans compte ni synchronisation.

## Mise en ligne

Le dépôt peut être publié tel quel avec GitHub Pages (Settings → Pages →
branche à servir), ou déposé sur un hébergeur statique comme Netlify.
