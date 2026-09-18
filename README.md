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
