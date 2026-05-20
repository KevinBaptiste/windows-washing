# Windows Washing

> Préparation automatisée de postes Windows 11 en un seul clic pour techniciens IT.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-blue?logo=powershell)](https://learn.microsoft.com/powershell/)
[![Windows 11](https://img.shields.io/badge/Windows-11_22H2+-0078D6?logo=windows11)](https://www.microsoft.com/windows/windows-11)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 📋 Sommaire

- [Présentation](#-présentation)
- [Fonctionnalités](#-fonctionnalités)
- [Démarrage rapide](#-démarrage-rapide)
- [Architecture](#-architecture)
- [Détail des étapes](#-détail-des-étapes)
- [Rapport d'exécution](#-rapport-dexécution)
- [Hébergement & distribution](#-hébergement--distribution)
- [Limitations connues](#-limitations-connues)
- [Contribuer](#-contribuer)

---

## 🎯 Présentation

**Windows Washing** est un script PowerShell « plug & play » destiné aux techniciens IT qui doivent préparer rapidement plusieurs postes Windows 11. Lancé en un clic via un fichier `.bat` hébergé sur un serveur web interne, il automatise entièrement la préparation d'un poste utilisateur final : debloat, suite bureautique, audit antivirus, navigateur, sans aucune interaction humaine durant l'exécution.

### Pourquoi ce projet ?

La préparation d'un poste neuf prend habituellement 30 à 60 minutes de clics manuels répétitifs (désinstallation des bloatwares, configuration Office, installation Chrome…). Ce script ramène l'intervention à **2 clics + UAC** côté technicien, le reste se déroule sans surveillance.

---

## ⚡ Fonctionnalités

- ✅ **Élévation administrateur automatique** via RunAs
- ✅ **Installation de PowerShell 7** (avec détection préalable pour éviter les réinstallations)
- ✅ **Debloat Windows 11** via [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat) avec configuration personnalisée
- ✅ **Désinstallation propre** de toutes les versions Office préexistantes (C2R + AppX/MSIX)
- ✅ **Installation Microsoft 365 Apps for Enterprise FR** via Office Deployment Tool
- ✅ **Suivi de progression** en temps réel (taille téléchargée + temps écoulé)
- ✅ **Audit antivirus** via WMI SecurityCenter2
- ✅ **Installation Google Chrome** via Winget
- ✅ **Rapport horodaté** sur le Bureau avec synthèse des échecs en en-tête
- ✅ **Retry automatique** (3 tentatives, pause 5s) sur les opérations réseau
- ✅ **Idempotent** : relançable sans dommage

---

## 🚀 Démarrage rapide

### Option 1 — Lancement direct depuis le serveur interne (recommandé pour techniciens)

1. Sur le poste cible, ouvrir un navigateur
2. Télécharger le `.bat` depuis votre serveur interne : `http://votre-serveur/win.bat`
3. Double-cliquer sur le fichier téléchargé
4. Accepter l'UAC

Le script télécharge automatiquement la dernière version du `.ps1` depuis ce repo et l'exécute.

### Option 2 — Exécution manuelle depuis le source

```powershell
# Cloner le repo
git clone https://github.com/KevinBaptiste/windows-washing.git
cd windows-washing

# Lancer le script
powershell -ExecutionPolicy Bypass -File .\washing-claude.ps1
```

### Prérequis

| Prérequis | Version | Remarque |
|-----------|---------|----------|
| Windows | 11 22H2+ | Compatible 10 partiellement |
| PowerShell | 5.1 | Pré-installé sur Windows |
| Winget | Récent | `App Installer` du Store |
| Connexion Internet | Active | Téléchargement ≈ 4-5 Go |
| Privilèges | Administrateur | Demandé via UAC |

---

## 🏗 Architecture

### Composants du projet

```
windows-washing/
├── washing-claude.ps1        # Script principal PowerShell 5.1
├── win.bat                   # Wrapper de lancement (téléchargement + exec)
├── docker/
│   └── compose.yml           # Stack Apache pour distribution interne
└── README.md
```

### Flux d'exécution

```
┌──────────────────────────────────────────────────────────┐
│  Technicien : double-clic win.bat                        │
└────────────────────┬─────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────┐
│  win.bat : télécharge washing-claude.ps1 depuis GitHub   │
└────────────────────┬─────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────┐
│  PowerShell 5.1 : élévation UAC → script principal       │
└────────────────────┬─────────────────────────────────────┘
                     │
       ┌─────────────┴───────────────┐
       ▼                             ▼
  Étapes 0-5 (séquentielles)    Logging double sortie
  + retry + idempotence         (console couleur + .txt)
```

---

## 🔧 Détail des étapes

### Étape 0 — Bootstrap

- Test du contexte administrateur, élévation automatique si nécessaire
- `Set-ExecutionPolicy Bypass -Scope Process`
- Force TLS 1.2 pour les téléchargements GitHub
- Initialisation des sources Winget
- Installation PowerShell 7 (skippée si déjà présent dans `C:\Program Files\PowerShell\7\`)

### Étape 1 — Win11Debloat

- Téléchargement de l'archive complète du repo Raphire/Win11Debloat (master)
- Extraction dans `%TEMP%\Win11Debloat-master\`
- Génération d'un `DefaultSettings.json` sur le Bureau (récupéré dynamiquement depuis le repo)
- Exécution dans un sous-processus PowerShell isolé (évite que son `Clear-Host` interne efface notre console parent)
- Paramètres : `-Silent -RemoveApps -DisableTelemetry -DisableBing`

### Étape 2 — Microsoft 365 Apps for Enterprise

**2.a — Désinstallation des Office existants**
- Click-to-Run via `OfficeClickToRun.exe` (`productstoremove=AllProducts`)
- AppX/MSIX Store correspondant aux 12 applications cibles (Access, Excel, OneDrive Groove, Skype for Business, OneDrive Desktop, OneNote, Outlook classic, Outlook new, PowerPoint, Publisher, Teams, Word)
- Suppression des paquets provisionnés (évite la réinstallation au prochain login)

**2.b — Installation ODT**
- Via Winget : `Microsoft.OfficeDeploymentTool`

**2.c — Génération du XML de configuration**
```xml
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="O365ProPlusRetail">
      <Language ID="fr-fr" />
      <ExcludeApp ID="Access" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
      <ExcludeApp ID="Publisher" />
    </Product>
    <Product ID="ProofingTools">
      <Language ID="en-gb" />
      <Language ID="en-us" />
    </Product>
  </Add>
  <Updates Enabled="TRUE" />
  <RemoveMSI />
  <Display Level="Full" AcceptEULA="TRUE" />
</Configuration>
```

**2.d — Installation avec suivi de progression**
- `Watch-OfficeInstallProgress` mesure la taille du dossier `C:\Program Files\Microsoft Office` toutes les secondes
- Affichage via `Write-Progress` : Mo téléchargés + temps écoulé
- Validation par **présence effective des binaires** (`WINWORD.EXE`, `EXCEL.EXE`) plutôt que par l'ExitCode d'ODT, peu fiable

### Étape 3 — Audit antivirus

- Lecture WMI `root\SecurityCenter2\AntiVirusProduct`
- Décodage du bitmask `productState` : nom du produit, état (Enabled/Disabled), signatures (UpToDate/Outdated)

### Étape 4 — Google Chrome

- Installation via Winget : `Google.Chrome`
- Tolérance ExitCode `-1978335189` (déjà installé)

### Étape 5 — Nettoyage

- Suppression des artefacts dans `%TEMP%` :
  - `Win11Debloat.zip`
  - `Win11Debloat-master/`
  - `configuration-install.xml`

---

## 📄 Rapport d'exécution

Un rapport horodaté est généré sur le Bureau à chaque exécution :

```
[Desktop]\PrepW11_Rapport_yyyyMMdd_HHmmss.txt
```

### Structure

```
========================================
RAPPORT D'EXÉCUTION — Préparation W11
Date : 2026-05-20 16:42:34
Machine : WIN-TEST
Utilisateur : Michel
========================================

>>> SYNTHÈSE DES ÉCHECS <<<
Aucun échec détecté
(ou liste des étapes en échec)

========================================
JOURNAL DÉTAILLÉ
========================================
[16:42:34] [INFO]    === Début du traitement (PowerShell 5.1) ===
[16:42:34] [SUCCESS] Étape 0 — Init Winget : succès
[16:42:35] [INFO]    Étape 0 — PowerShell 7 : PowerShell 7.4.1 déjà installé, installation skippée.
...
```

### Codes couleur console

| Niveau | Couleur | Signification |
|--------|---------|---------------|
| INFO | Gris | Information secondaire |
| SUCCESS | Vert | Étape réussie |
| WARN | Jaune | Avertissement non bloquant |
| ERROR | Rouge | Erreur capturée |

---

## 🌐 Hébergement & distribution

### Stack Docker (Apache)

Le fichier `.bat` est distribué via un conteneur Apache derrière un reverse proxy Nginx.

```yaml
services:
  web:
    image: httpd:alpine
    container_name: apache
    volumes:
      - ./files:/usr/local/apache2/htdocs:ro
    networks:
      - subnet1
    restart: unless-stopped

networks:
  subnet1:
    external: true
```

### Workflow technicien

1. Sur chaque poste à préparer, ouvrir `http://votre-serveur/win.bat`
2. Télécharger + double-clic → UAC → exécution
3. Le `.bat` télécharge la dernière version du `.ps1` depuis GitHub
4. **Mise à jour centralisée** : modifier le `.ps1` sur le repo = tous les futurs déploiements bénéficient des corrections sans intervention sur les clés USB ou postes

---

## ⚠️ Limitations connues

- **Avertissement SmartScreen** : le `.bat` téléchargé déclenche le Mark-of-the-Web. Inévitable sans certificat de signature de code (~200-400 €/an pour un cert OV/EV).
- **Activation Microsoft 365** : `AUTOACTIVATE=0` désactive l'activation silencieuse. Un login Microsoft interactif post-installation est requis.
- **ExitCode ODT** : `setup.exe /configure` peut retourner un code non nul même en cas de succès (il délègue à `OfficeClickToRun.exe`). La validation se fait donc par présence effective des binaires.
- **Win11Debloat** : dépend de la branche `master` du repo upstream. Tout changement de structure peut nécessiter une adaptation.
- **Politique d'erreur permissive** sur l'exécution Win11Debloat : `$ErrorActionPreference = 'Continue'` local au bloc d'exécution (le script écrit sur stderr des messages informatifs qui seraient sinon levés comme exceptions).

---

## 🧪 Tests

### Sandbox / VM recommandée

- **Windows Sandbox** (Windows 11 Pro/Enterprise) pour des tests à blanc rapides
- **Hyper-V** avec snapshot pour des tests itératifs
- Temps d'exécution complet estimé : **15 à 30 minutes** (dépend du débit pour le téléchargement Office ≈ 4 Go)

### Critères de validation

- ✅ Aucun prompt utilisateur durant l'exécution
- ✅ Toutes les étapes échouées synthétisées en en-tête du rapport
- ✅ Script idempotent (relançable sans dommage)
- ✅ Codes de sortie capturés pour toutes les commandes externes

---

## 🛠 Stack technique

| Composant | Rôle |
|-----------|------|
| PowerShell 5.1 | Runtime principal du script |
| PowerShell 7 | Installé en parallèle, non utilisé par le script |
| Winget | Gestion des paquets (PS7, Chrome, ODT) |
| Office Deployment Tool | Installation Microsoft 365 |
| Win11Debloat | Suppression bloatwares Windows 11 |
| Apache (httpd:alpine) | Distribution du `.bat` |
| Nginx | Reverse proxy + HTTPS |
| Docker Compose | Orchestration de la stack web |

---

## 🤝 Contribuer

Les contributions sont bienvenues. Pour contribuer :

1. Forker le repo
2. Créer une branche : `git checkout -b feature/ma-feature`
3. Tester en sandbox Windows 11
4. Commiter : `git commit -m "feat: description"`
5. Ouvrir une Pull Request

### Conventions

- **Commentaires en français** dans le code (le pourquoi, pas le quoi)
- **Verbes PowerShell approuvés** uniquement (`Get-Verb`)
- **PascalCase** pour les fonctions, **camelCase** pour les variables locales
- **Comment-based help** sur chaque fonction publique (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`)
- **PSScriptAnalyzer** : aucun warning sur les règles par défaut

---

## 📝 Licence

MIT — voir [LICENSE](LICENSE).

---

## 🙏 Remerciements

- [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat) pour l'outil de debloat
- [Microsoft Office Deployment Tool](https://www.microsoft.com/download/details.aspx?id=49117) pour la voie officielle d'installation M365
- La communauté PowerShell pour les bonnes pratiques

---

**Auteur** : [Kevin Baptiste](https://github.com/KevinBaptiste) — BTST
**Version** : 1.1.0
**Dernière mise à jour** : Mai 2026
