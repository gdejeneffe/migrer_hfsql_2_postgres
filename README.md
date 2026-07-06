# ETL Générique — HFSQL → PostgreSQL

## 🤖 À propos

Ce script a été **généré avec l'aide d'une IA** (Claude, Anthropic) à partir d'un besoin récurrent : migrer une analyse WINDEV vers PostgreSQL sans réécrire la logique à chaque projet.

- Auto-détection des colonnes, clés uniques, PK, colonnes binaires et séquences via `information_schema`
- Seule la section `CONFIG` change d'un programme à l'autre
- **Non testé en production** — relecture et validation manuelle requises avant tout usage réel

## ⚠️ Disclaimer

Code fourni "tel quel". Vérifie la logique (notamment la gestion des FK, des orphelins et des colonnes binaires) avant de l'exécuter sur une base contenant des données réelles. Un backup avant migration reste la moindre des choses.

## 🔧 Prérequis

- Connecteur Natif PostgreSQL (WINDEV) + `libpq.dll` accessible
- Schéma cible généré depuis WINDEV, vide, **sans les FK**
- PK mono-colonne par table

## 📝 Contributions

Suggestions et corrections bienvenues via issue ou PR.

## 📄 Licence

MIT — voir [LICENSE](./LICENSE). Fourni "tel quel", sans garantie.
