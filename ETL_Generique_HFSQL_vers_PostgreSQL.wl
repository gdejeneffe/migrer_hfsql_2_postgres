// ============================================================================
//  ETL GÉNÉRIQUE — HFSQL Client/Serveur -> PostgreSQL (Connecteur Natif)
// ----------------------------------------------------------------------------
//  Migre TOUTE analyse WINDEV : énumération auto des tables/colonnes, INSERT
//  paramétré (clés préservées), binaire via decode(hex), FK/nettoyage à part.
//
//  Réutilisable d'un programme à l'autre : SEULE la section CONFIG change.
//  Auto-détecté (aucune saisie) :
//    - colonnes cible (intersection PG)      -> exclut les colonnes non générées
//                                                (types non supportés : MotDePasse…)
//    - colonnes UNIQUE (vide -> NULL)        -> information_schema
//    - clé primaire par table (UPDATE binaire)-> information_schema
//    - colonnes binaires (exclues INSERT)    -> TypeVar (wlBuffer/wlMémoBinaire)
//    - dates/heures vides -> NULL            -> TypeVar
//    - séquences SERIAL à resynchroniser     -> column_default 'nextval%'
//
//  Prérequis :
//    - Connecteur Natif PostgreSQL installé (+ libpq.dll accessible).
//    - Schéma cible déjà créé et VIDE, SANS les FK (générées par WINDEV :
//      Analyse -> Générer le script SQL -> PostgreSQL). FK appliquées APRÈS.
//    - PK simple (mono-colonne) par table (cas courant).
//
//  ⚠ À valider dans l'IDE : parcours d'un résultat information_schema
//    (hRequêteSansCorrection, sans paramètre) via POUR TOUT.
// ============================================================================

PROCÉDURE ETL_Generique()

// ======================= CONFIG (à adapter par programme) ===================
CONSTANT
//HFSQL
	SRC_SERVEUR     = "[InsertYourInformation]"       // HFSQL C/S
	SRC_BASE        = "[InsertYourInformation]"
	SRC_USER        = "[InsertYourInformation]"
	SRC_MDP         = "<MDP_ADMIN_HFSQL>"
	SRC_MDP_FICHIER = "<MDP_FICHIER_HPASSE>"            // mot de passe fichier (HPasse), "" si aucun
//Postgres
	PG_SERVEUR      = "[InsertYourInformation]"        // IP seule (le port va dans InfosEtendues)
	PG_PORT         = "5432"
	PG_BASE         = "[InsertYourInformation]"
	PG_USER         = "postgres"
	PG_MDP          = "<MDP_POSTGRES>"
FIN

// Tables exclues + colonnes horodatage-auto : DÉCLARÉES ici, REMPLIES dans le
// corps (le code exécutable doit suivre les procédures internes).
gtabTablesExclues est un tableau associatif de booléens
gtabColExclues    est un tableau associatif de booléens

// ======================= MÉTADONNÉES (auto, remplies au démarrage) ==========
gtabColPG    est un tableau associatif de booléens   // "table.col" présentes côté PG
gtabUnique   est un tableau associatif de booléens   // "table.col" sous contrainte UNIQUE
gtabPK       est un tableau associatif de chaînes     // table -> colonne PK
gtabBinTable est un tableau de chaînes                // tables ayant une colonne binaire
gtabBinCol   est un tableau de chaînes                // colonne binaire correspondante

cnxSource est une Connexion
cnxCible  est une Connexion
sFichier, sListeFic  sont des chaînes
nTotal    est un entier
i         est un entier
tabRapport est un tableau associatif d'entiers


// ============================================================================
//  Charge les métadonnées cible depuis PostgreSQL (3 requêtes sans paramètre).
// ============================================================================
PROCÉDURE INTERNE ChargerMetadonnees()
	sdMeta est une Source de Données

	// Colonnes existantes côté PG (pour l'intersection)
	HExécuteRequêteSQL(sdMeta, cnxCible, hRequêteSansCorrection, ...
		"SELECT table_name, column_name FROM information_schema.columns " + ...
		"WHERE table_schema = 'public'")
	POUR TOUT sdMeta
		gtabColPG[sdMeta.table_name + "." + sdMeta.column_name] = Vrai
	FIN
	HAnnuleDéclaration(sdMeta)

	// Colonnes sous contrainte UNIQUE
	HExécuteRequêteSQL(sdMeta, cnxCible, hRequêteSansCorrection, ...
		"SELECT tc.table_name AS t, kcu.column_name AS c " + ...
		"FROM information_schema.table_constraints tc " + ...
		"JOIN information_schema.key_column_usage kcu " + ...
		"  ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema " + ...
		"WHERE tc.table_schema = 'public' AND tc.constraint_type = 'UNIQUE'")
	POUR TOUT sdMeta
		gtabUnique[sdMeta.t + "." + sdMeta.c] = Vrai
	FIN
	HAnnuleDéclaration(sdMeta)

	// Clé primaire (mono-colonne) par table
	HExécuteRequêteSQL(sdMeta, cnxCible, hRequêteSansCorrection, ...
		"SELECT tc.table_name AS t, kcu.column_name AS c " + ...
		"FROM information_schema.table_constraints tc " + ...
		"JOIN information_schema.key_column_usage kcu " + ...
		"  ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema " + ...
		"WHERE tc.table_schema = 'public' AND tc.constraint_type = 'PRIMARY KEY'")
	POUR TOUT sdMeta
		gtabPK[sdMeta.t] = sdMeta.c
	FIN
	HAnnuleDéclaration(sdMeta)


// ============================================================================
//  Copie d'une table par INSERT paramétré. Renvoie nb écrits, -1 si erreur.
//  Collecte au passage les colonnes binaires (traitées ensuite par CopierBinaire).
// ============================================================================
PROCÉDURE INTERNE CopierTable(sFic est chaîne)
	sRub, sListeRub, sCle          sont des chaînes
	sColonnes, sValeurs, sSQL, sVal sont des chaînes
	nEcrits, j, nType              sont des entiers = 0
	tabCols   est un tableau de chaînes
	tabParam  est un tableau de chaînes
	tabEstDate est un tableau de booléens
	sdInsert est une Source de Données
	sdVide   est une Source de Données
	tabEnr    est un tableau associatif de Variant
	tabBuffer est un tableau de tableaux associatifs de Variant

	// --- Phase 1 : lecture source (bufferisée, curseur stable, HPasse) ---
	HChangeConnexion(sFic, cnxSource)
	HPasse(sFic, SRC_MDP_FICHIER)
	SI PAS HOuvre(sFic) ALORS
		Trace("[ERR ouverture] " + sFic + " : " + HErreurInfo(hErrComplet))
		RENVOYER -1
	FIN
	sListeRub = HListeRubrique(sFic)

	POUR TOUTE CHAÎNE sRub DE sListeRub SÉPARÉE PAR RC
		SI sRub = "" ALORS CONTINUER
		sCle = sFic + "." + sRub
		SI gtabColPG[sCle] <> Vrai ALORS CONTINUER      // absente côté PG -> exclue (auto)
		SI gtabColExclues[sCle] = Vrai ALORS CONTINUER  // horodatage auto (config)
		nType = TypeVar({sFic + "." + sRub})
		SI nType = wlBuffer OU nType = wlMémoBinaire ALORS
			Ajoute(gtabBinTable, sFic)                  // binaire -> CopierBinaire (après)
			Ajoute(gtabBinCol, sRub)
			CONTINUER
		FIN
		j++
		Ajoute(tabCols, sRub)
		Ajoute(tabParam, "p" + j)
		Ajoute(tabEstDate, (nType = wlDate OU nType = wlDateHeure))
		SI j > 1 ALORS
			sColonnes += ", "
			sValeurs  += ", "
		FIN
		sColonnes += """" + sRub + """"
		sValeurs  += "{p" + j + "}"
	FIN

	SI tabCols.Occurrence = 0 ALORS
		Trace("[SKIP] " + sFic + " : aucune colonne")
		HFerme(sFic)
		RENVOYER 0
	FIN
	sSQL = "INSERT INTO """ + sFic + """ (" + sColonnes + ") VALUES (" + sValeurs + ")"

	HLitPremier(sFic)
	TANTQUE PAS HEnDehors(sFic)
		SupprimeTout(tabEnr)
		POUR j = 1 À tabCols.Occurrence
			sVal = {sFic + "." + tabCols[j]}
			SI tabEstDate[j] ET (sVal = "" OU Gauche(sVal, 4) = "0000") ALORS
				tabEnr[tabParam[j]] = Null                                  // date vide -> NULL
			SINON SI gtabUnique[sFic + "." + tabCols[j]] = Vrai ET SansEspace(sVal) = "" ALORS
				tabEnr[tabParam[j]] = Null                                  // UNIQUE vide -> NULL
			SINON
				tabEnr[tabParam[j]] = {sFic + "." + tabCols[j]}
			FIN
		FIN
		Ajoute(tabBuffer, tabEnr)
		HLitSuivant(sFic)
	FIN
	HFerme(sFic)

	// --- Phase 2 : écriture cible (fichier rebranché sur PG, INSERT mode défaut) ---
	HChangeConnexion(sFic, cnxCible)
	SI PAS HExécuteRequêteSQL(sdVide, cnxCible, "DELETE FROM " + sFic) ALORS
		Trace("[ERR DELETE] " + sFic + " : " + HErreurInfo(hErrComplet))
	FIN
	HAnnuleDéclaration(sdVide)

	POUR TOUT tabEnr DE tabBuffer
		POUR j = 1 À tabParam.Occurrence
			{"sdInsert." + tabParam[j]} = tabEnr[tabParam[j]]
		FIN
		SI HExécuteRequêteSQL(sdInsert, cnxCible, sSQL) ALORS
			nEcrits++
		SINON
			Trace("[ERR INSERT] " + sFic + " : " + HErreurInfo(hErrComplet))
		FIN
	FIN
	HAnnuleDéclaration(sdInsert)
	Trace("[OK] " + sFic + " : " + nEcrits + " lignes")
	RENVOYER nEcrits


// ============================================================================
//  Copie d'UNE colonne binaire : UPDATE decode('<hex>','hex') après les INSERT.
// ============================================================================
PROCÉDURE INTERNE CopierBinaire(sTable est chaîne, sBinCol est chaîne, sPKCol est chaîne)
	sHex, sSQL sont des chaînes
	nMaj est un entier = 0
	k    est un entier              // local : ne pas réutiliser le "i" de la boucle appelante
	sdUpd est une Source de Données
	tabPK  est un tableau de chaînes
	tabHex est un tableau de chaînes

	SI sPKCol = "" ALORS
		Trace("[ERR BIN] " + sTable + " : PK inconnue -> binaire ignoré")
		RETOUR
	FIN

	HChangeConnexion(sTable, cnxSource)
	HPasse(sTable, SRC_MDP_FICHIER)
	SI PAS HOuvre(sTable) ALORS
		Trace("[ERR BIN ouverture] " + sTable + " : " + HErreurInfo(hErrComplet))
		RETOUR
	FIN
	HLitPremier(sTable)
	TANTQUE PAS HEnDehors(sTable)
		sHex = BufferVersHexa({sTable + "." + sBinCol}, SansRegroupement, SansLigne)
		SI sHex <> "" ALORS
			Ajoute(tabPK, {sTable + "." + sPKCol})
			Ajoute(tabHex, sHex)
		FIN
		HLitSuivant(sTable)
	FIN
	HFerme(sTable)

	HChangeConnexion(sTable, cnxCible)
	POUR k = 1 À tabPK.Occurrence
		sSQL = "UPDATE """ + sTable + """ SET """ + sBinCol + """ = decode('" + tabHex[k] + ...
			"','hex') WHERE """ + sPKCol + """ = '" + tabPK[k] + "'"
		SI HExécuteRequêteSQL(sdUpd, cnxCible, hRequêteSansCorrection, sSQL) ALORS
			nMaj++
		SINON
			Trace("[ERR BIN UPDATE] " + sTable + " : " + HErreurInfo(hErrComplet))
		FIN
	FIN
	HAnnuleDéclaration(sdUpd)
	Trace("[BIN] " + sTable + "." + sBinCol + " : " + nMaj + " maj")


// ============================================================================
//  Resynchronise toutes les séquences SERIAL (valeurs insérées explicitement).
// ============================================================================
PROCÉDURE INTERNE ResyncSequences()
	sdSeq est une Source de Données
	sdRun est une Source de Données
	sT, sC, sSQL sont des chaînes
	nSeq est un entier = 0

	HExécuteRequêteSQL(sdSeq, cnxCible, hRequêteSansCorrection, ...
		"SELECT table_name AS t, column_name AS c FROM information_schema.columns " + ...
		"WHERE table_schema = 'public' AND column_default LIKE 'nextval%'")
	POUR TOUT sdSeq
		sT = sdSeq.t
		sC = sdSeq.c
		sSQL = "SELECT setval(pg_get_serial_sequence('""" + sT + """','" + sC + "'), " + ...
			"COALESCE((SELECT MAX(""" + sC + """) FROM """ + sT + """),1))"
		SI HExécuteRequêteSQL(sdRun, cnxCible, hRequêteSansCorrection, sSQL) ALORS
			nSeq++
		SINON
			Trace("[ERR SEQ] " + sT + "." + sC + " : " + HErreurInfo(hErrComplet))
		FIN
		HAnnuleDéclaration(sdRun)
	FIN
	HAnnuleDéclaration(sdSeq)
	Trace("[SEQ] " + nSeq + " séquence(s) resynchronisée(s)")


// ============================== CORPS PRINCIPAL =============================
// CONFIG (remplissage) : tables à ne pas migrer + colonnes horodatage-auto
// COMPLETER SELON LA DB
gtabTablesExclues["TraceLog"]     = Vrai       // horodatage automatique
gtabTablesExclues["table1"]    = Vrai
gtabTablesExclues["Table2"] = Vrai


cnxSource.Provider      = hAccèsHFClientServeur
cnxSource.Serveur       = SRC_SERVEUR
cnxSource.BaseDeDonnées = SRC_BASE
cnxSource.Utilisateur   = SRC_USER
cnxSource.MotDePasse    = SRC_MDP
SI PAS HOuvreConnexion(cnxSource) ALORS
	Erreur("Connexion HFSQL source impossible : " + HErreurInfo(hErrComplet))
	RENVOYER Faux
FIN

cnxCible.Provider      = hAccèsNatifPostgreSQL
cnxCible.Serveur       = PG_SERVEUR
cnxCible.InfosEtendues = "Server Port=" + PG_PORT
cnxCible.BaseDeDonnées = PG_BASE
cnxCible.Utilisateur   = PG_USER
cnxCible.MotDePasse    = PG_MDP
SI PAS HOuvreConnexion(cnxCible) ALORS
	Erreur("Connexion PostgreSQL cible impossible : " + HErreurInfo(hErrComplet))
	HFermeConnexion(cnxSource)
	RENVOYER Faux
FIN

ChargerMetadonnees()

// 1) Toutes les tables (hors exclues) par INSERT paramétré
sListeFic = HListeFichier()
POUR TOUTE CHAÎNE sFichier DE sListeFic SÉPARÉE PAR RC
	SI sFichier = "" ALORS CONTINUER
	SI gtabTablesExclues[sFichier] = Vrai ALORS CONTINUER
	nTotal = CopierTable(sFichier)
	SI nTotal >= 0 ALORS tabRapport[sFichier] = nTotal
FIN

// 2) Colonnes binaires (collectées pendant la phase 1) -> UPDATE decode(hex)
POUR i = 1 À gtabBinTable.Occurrence
	CopierBinaire(gtabBinTable[i], gtabBinCol[i], gtabPK[gtabBinTable[i]])
FIN

// 3) Resync des séquences SERIAL
ResyncSequences()

// Rapport
Trace("===== RAPPORT MIGRATION GÉNÉRIQUE =====")
POUR TOUT ÉLÉMENT nTotal, sFichier DE tabRapport
	Trace(sFichier + " : " + nTotal)
FIN

HFermeConnexion(cnxSource)
HFermeConnexion(cnxCible)
RENVOYER Vrai

// ============================================================================
//  RESTE MANUEL / PROGRAMME-SPÉCIFIQUE (hors de ce script) :
//   - Générer le schéma cible depuis WINDEV, relâcher les DATE NOT NULL si la
//     source contient des dates vides (sinon violation NOT NULL).
//   - Après migration : détecter les orphelins (LEFT JOIN parent) et décider
//     délier(NULL)/supprimer, PUIS appliquer les FK (leur succès = test d'intégrité).
//   - Convention "valeur nulle" des FK (NULL SQL vs sentinelle UUID) selon le
//     programme : adapter le nettoyage orphelins en conséquence.
// ============================================================================
