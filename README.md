# ETL Générique — HFSQL → PostgreSQL

## 🤖 À propos

Ce script a été **généré avec l'aide d'une IA** (Claude, Anthropic) à partir d'un besoin récurrent : migrer une analyse WINDEV vers PostgreSQL sans réécrire la logique à chaque projet.

- Auto-détection des colonnes, clés uniques, PK, colonnes binaires et séquences via `information_schema`
- Seule la section `CONFIG` change d'un programme à l'autre
- **Non testé en production** — relecture et validation manuelle requises avant tout usage réel

## 🐛 Corrections connues

**2026-09-18 — casse des noms.** WINDEV nomme en MAJUSCULES, PostgreSQL replie tout
identifiant non protégé en minuscules. Les clés des tableaux associatifs venaient donc
des deux casses à la fois : `DOCUMENT.REF_PROCEDURE` à la lecture,
`document.ref_procedure` à l'écriture depuis `information_schema`.

Résultat : aucune clé ne correspondait, **toutes les colonnes étaient exclues** par un
`CONTINUER` silencieux, sans la moindre erreur. Le défaut restait invisible tant que le
schéma cible gardait les majuscules entre guillemets ; il se révèle dès qu'on suit les
usages PostgreSQL.

Toutes les clés sont désormais normalisées en minuscules, des deux côtés — y compris
`gtabPK`, dont la lecture croisait un nom HFSQL avec un index PostgreSQL au moment de
réinjecter les colonnes binaires.

**2026-09-18 — noms réels du schéma cible.** Le script écrivait
`INSERT INTO "DOCUMENT" ("REF_PROCEDURE")`, c'est-à-dire le nom HFSQL **entre
guillemets**. En PostgreSQL, un identifiant protégé est pris littéralement : la table
`DOCUMENT` n'existe pas si le schéma s'appelle `document`. Même problème sur l'`UPDATE`
de réinjection des binaires.

`information_schema` donne le nom **tel que PostgreSQL le connaît** : il est désormais
mémorisé et employé partout. Le script fonctionne donc quelle que soit la convention du
schéma cible, majuscules ou minuscules.

**2026-09-18 — colonnes `IDENTITY`.** La resynchronisation des séquences ne cherchait que
`column_default LIKE 'nextval%'`, la signature d'un `SERIAL`. Une colonne
`GENERATED … AS IDENTITY` (PostgreSQL 10+) a un `column_default` **nul** : aucune de ses
séquences n'était resynchronisée, et le premier `INSERT` applicatif après reprise entrait
en collision de clé. La détection couvre maintenant `is_identity = 'YES'`.

**2026-09-18 — `TRUNCATE` au lieu de `DELETE`.** Plus rapide, et il remet la table dans un
état franc. Un `DELETE` sur une table volumineuse laisse par ailleurs le travail au
VACUUM.

## ⚠️ Disclaimer

Code fourni "tel quel". Vérifiez la logique (notamment la gestion des FK, des orphelins et des colonnes binaires) avant de l'exécuter sur une base contenant des données réelles. Un backup avant toute migration est indispensable.

## 🔧 Prérequis

- Connecteur Natif PostgreSQL (WINDEV) + `libpq.dll` accessible
- Schéma cible généré depuis WINDEV, vide, **sans les FK**
- PK mono-colonne par table

## 📝 Contributions

Suggestions et corrections bienvenues via issue ou PR.

## 📄 Licence

MIT — voir [LICENSE](./LICENSE). Fourni "tel quel", sans garantie.
