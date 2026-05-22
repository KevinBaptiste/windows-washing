
<#
.SYNOPSIS
    Script de préparation automatisée d'un poste Windows 10/11 (exécution monobloc PowerShell 5.1).

.DESCRIPTION
    Script "Plug & Play" lancé via clic-droit → "Exécuter avec PowerShell" :
      - Élévation administrateur automatique
      - Création d'un compte admin local de secours (credential persisté sur disque)
      - Mise à jour des sources Winget (auto-install si absent)
      - Installation de PowerShell 7 via Winget (conservée mais non utilisée pour la suite)
      - Debloat Windows (Win11Debloat / Raphire) — ref Git pinnée + CustomAppsList optionnelle
      - Audit de l'antivirus actif
      - Installation Google Chrome, VLC, Foxit PDF Reader (via Winget)
      - Désinstallation d'Office existant (si détecté) puis installation de Microsoft 365 Apps for Entreprise FR via ODT
      - Nettoyage des fichiers temporaires
    Aucune interaction utilisateur n'est requise. Un rapport et le credential admin
    sont générés dans %USERPROFILE%.

.EXAMPLE
    Clic-droit sur le fichier .ps1 → "Exécuter avec PowerShell".

.NOTES
    Auteur  : Kevin (BTST)
    Version : 1.3.0
    Date    : 2026-05-22
    Cible   : Windows 10 1809+ / Windows 11 22H2+, PowerShell 5.1
#>
 
#region ============================== BOOTSTRAP ====================================
 
# Politique d'erreur globale : toute exception non gérée stoppe l'étape courante.
$ErrorActionPreference = 'Stop'
 
# Forçage TLS 1.2 (nécessaire pour Invoke-WebRequest sous PS 5.1 sur GitHub).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
 
function Test-AdminContext {
    <#
    .SYNOPSIS
        Vérifie si la session courante dispose des privilèges Administrateur.
    .OUTPUTS
        [bool] $true si élevé, $false sinon.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
 
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
 
# Si non élevé, on relance le script en RunAs en préservant son chemin d'origine.
if (-not (Test-AdminContext)) {
    # $PSCommandPath est plus fiable que $MyInvocation lors d'une relance.
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
 
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        Write-Host "Impossible de déterminer le chemin du script pour l'élévation." -ForegroundColor Red
        exit 1
    }
 
    Start-Process -FilePath 'powershell.exe' `
                  -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"") `
                  -Verb RunAs
    exit 0
}
 
# À ce stade, la session est élevée. On autorise les scripts pour le processus uniquement.
Set-ExecutionPolicy Bypass -Scope Process -Force
 
# Constantes globales (déclarées avant tout usage).
$Script:TempDir         = $env:TEMP
# Rapport ET credential sont stockés côte-à-côte dans $env:USERPROFILE.
# Le credential dérive du dossier de $Script:LogPath dans New-AdminAccount → couplage garanti.
$Script:LogPath         = Join-Path $env:USERPROFILE ("Rapport_Washing_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

# --- Configuration Win11Debloat (pinning + config externe) ---
# Ref Git pinnée (tag, branche, ou SHA complet). Évite la dérive de la branche master.
# Mettre à jour manuellement après vérification d'une release upstream :
# https://github.com/Raphire/Win11Debloat/releases
$Script:Win11DebloatRef = 'refs/tags/v25.10.18'

# Optionnel : raw URL d'un CustomAppsList.txt hébergé sur TON propre GitHub.
# Si renseigné, le script utilise -RemoveAppsCustom au lieu de -RemoveApps (liste upstream).
# Format : un identifiant d'AppX par ligne (ex: 'Microsoft.BingNews').
# Exemple : 'https://raw.githubusercontent.com/<user>/<repo>/<sha>/CustomAppsList.txt'
$Script:Win11DebloatCustomAppsListUrl = ''
 
#endregion ===========================================================================
 
#region ============================ LOGGING =========================================
 
# Collection d'événements journalisés ; les échecs sont synthétisés en tête de rapport.
$Script:LogEntries = New-Object System.Collections.Generic.List[string]
$Script:Failures   = New-Object System.Collections.Generic.List[string]
$Script:AdminAccount  = $null
$Script:AdminPassword = $null
$Script:AdminCredPath = $null
 
function Write-LogEntry {
    <#
    .SYNOPSIS
        Écrit une entrée journalisée en console (colorée) et en mémoire (rapport).
    .PARAMETER Message
        Texte à journaliser.
    .PARAMETER Level
        Niveau de gravité : INFO, SUCCESS, ERROR ou WARN.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'SUCCESS', 'ERROR', 'WARN')] [string] $Level = 'INFO'
    )
 
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line      = "[{0}] [{1}] {2}" -f $timestamp, $Level.PadRight(7), $Message
 
    # Couleur console selon le niveau.
    $color = switch ($Level) {
        'SUCCESS' { 'Green' }
        'ERROR'   { 'Red' }
        'WARN'    { 'Yellow' }
        default   { 'Gray' }
    }
 
    Write-Host $line -ForegroundColor $color
    $Script:LogEntries.Add($line) | Out-Null
}
 
function Add-Failure {
    <#
    .SYNOPSIS
        Enregistre un échec d'étape pour la synthèse en tête de rapport.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StepLabel,
        [Parameter(Mandatory)] [string] $Reason
    )
    $Script:Failures.Add("[$StepLabel] : $Reason") | Out-Null
}
 
#endregion ===========================================================================
 
#region ============================ HELPERS =========================================
 
function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Exécute un scriptblock avec retry automatique (3 tentatives, pause 5s).
    .PARAMETER Action
        Le bloc de code à exécuter.
    .PARAMETER Label
        Libellé descriptif pour le journal.
    .OUTPUTS
        [bool] $true si succès, $false si échec après 3 tentatives.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [Parameter(Mandatory)] [string]      $Label,
        [int] $MaxAttempts = 3,
        [int] $DelaySeconds = 5
    )
 
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-LogEntry -Message "$Label : tentative $attempt/$MaxAttempts" -Level INFO
            & $Action
            Write-LogEntry -Message "$Label : succès" -Level SUCCESS
            return $true
        }
        catch {
            Write-LogEntry -Message "$Label : échec tentative $attempt — $($_.Exception.Message)" -Level WARN
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }
 
    Write-LogEntry -Message "$Label : abandon après $MaxAttempts tentatives" -Level ERROR
    return $false
}
 
function Find-OdtSetup {
    <#
    .SYNOPSIS
        Localise setup.exe de l'Office Deployment Tool.
    .OUTPUTS
        [string] Chemin complet de setup.exe, ou $null si introuvable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
 
    $candidates = @(
        (Join-Path $env:ProgramFiles 'OfficeDeploymentTool\setup.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'OfficeDeploymentTool\setup.exe')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
 
    # Fallback : recherche large dans Program Files.
    $found = Get-ChildItem -Path $env:ProgramFiles -Recurse -Filter 'setup.exe' -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -match 'OfficeDeploymentTool' } |
             Select-Object -First 1
    if ($found) { return $found.FullName }
 
    return $null
}

function Watch-OfficeInstallProgress {
    <#
    .SYNOPSIS
        Surveille l'installation Office en affichant la taille téléchargée en temps réel.
    .DESCRIPTION
        Tant que le process ODT tourne, la fonction mesure périodiquement la taille du
        dossier Office cible et affiche les Mo téléchargés via Write-Progress (sans %).
    .PARAMETER Process
        Objet System.Diagnostics.Process renvoyé par Start-Process -PassThru.
    .PARAMETER PollSeconds
        Intervalle entre deux mesures (défaut : 1s).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [int] $PollSeconds = 1
    )

    # Dossiers à surveiller : ODT télécharge d'abord dans le cache C2R (ProgramData)
    # puis copie/déploie dans Program Files. Surveiller les deux donne une métrique
    # plus fidèle dès le début du téléchargement (sinon on reste à 0 Mo plusieurs minutes).
    $officePaths = @(
        (Join-Path $env:ProgramFiles 'Microsoft Office'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office'),
        (Join-Path $env:ProgramData 'Microsoft\ClickToRun'),
        (Join-Path $env:ProgramData 'Microsoft\Office\ClickToRun')
    )

    $startTime = Get-Date

    while (-not $Process.HasExited) {
        $totalBytes = 0
        foreach ($p in $officePaths) {
            if (Test-Path -LiteralPath $p) {
                try {
                    $totalBytes += (Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
                                    Measure-Object -Property Length -Sum).Sum
                }
                catch {
                    # Lecture concurrente possible pendant l'install : on ignore.
                }
            }
        }

        $currentMB  = [math]::Round($totalBytes / 1MB, 0)
        $elapsed    = (Get-Date) - $startTime
        $elapsedFmt = "{0:hh\:mm\:ss}" -f $elapsed

        Write-Progress -Activity "Installation Microsoft 365 Apps for Entreprise" `
                       -Status ("Téléchargé : {0} Mo  |  Écoulé : {1}" -f $currentMB, $elapsedFmt)

        Start-Sleep -Seconds $PollSeconds
    }

    Write-Progress -Activity "Installation Microsoft 365 Apps for Entreprise" -Completed
}

function Install-WingetPackage {
    <#
    .SYNOPSIS
        Helper générique : installe un paquet Winget avec pré-check de présence et retry.
    .DESCRIPTION
        Vérifie d'abord la présence d'un binaire (DetectionPaths). Si déjà installé, skip.
        Sinon, installation silencieuse via Winget avec retry, en tolérant les ExitCodes
        "déjà présent". Centralise les arguments communs (--silent, --accept-*-agreements).
    .PARAMETER Label
        Libellé d'étape pour le journal et la synthèse d'échecs.
    .PARAMETER WingetId
        Identifiant exact du paquet Winget (ex: 'Google.Chrome').
    .PARAMETER DisplayName
        Nom lisible pour les logs (ex: 'Google Chrome').
    .PARAMETER DetectionPaths
        Chemins de binaires à tester pour skipper l'install. Vide = pas de pré-check.
    .PARAMETER ExtraArgs
        Arguments supplémentaires passés à winget (ex: '--scope', 'machine').
    .PARAMETER ToleratedExitCodes
        Codes de sortie Winget acceptés comme succès (par défaut : 0 + déjà-installé).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $Label,
        [Parameter(Mandatory)] [string]   $WingetId,
        [Parameter(Mandatory)] [string]   $DisplayName,
        [string[]] $DetectionPaths     = @(),
        [string[]] $ExtraArgs          = @(),
        [int[]]    $ToleratedExitCodes = @(0, -1978335189)
    )

    Write-LogEntry -Message "$Label : démarrage" -Level INFO

    # Pré-check : si un des chemins de détection existe, on skip l'install.
    if ($DetectionPaths.Count -gt 0) {
        $existing = $DetectionPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($existing) {
            try {
                $ver = (Get-Item -LiteralPath $existing).VersionInfo.ProductVersion
                Write-LogEntry -Message "$Label : $DisplayName $ver déjà installé, installation skippée." -Level SUCCESS
            }
            catch {
                Write-LogEntry -Message "$Label : $DisplayName déjà installé (version non lisible), installation skippée." -Level SUCCESS
            }
            return
        }
    }

    Write-LogEntry -Message "$Label : $DisplayName absent, installation via Winget." -Level INFO

    $ok = Invoke-WithRetry -Label $Label -Action {
        $wingetArgs = @('install', '--id', $WingetId,
                        '--silent', '--accept-source-agreements', '--accept-package-agreements') + $ExtraArgs
        & winget @wingetArgs | Out-Null
        if ($ToleratedExitCodes -notcontains $LASTEXITCODE) {
            throw "Winget $DisplayName ExitCode = $LASTEXITCODE"
        }
    }

    if (-not $ok) {
        Add-Failure -StepLabel $Label -Reason "Installation $DisplayName en échec."
    }
}

#endregion ===========================================================================

#region ============================ STEPS ===========================================

function New-AdminAccount {
    [CmdletBinding()]
    param(
        [string]$Username = "Nlyadm",
        [int]$Length = 24
    )

    # Vérification des droits administrateur
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Cette fonction nécessite des droits administrateur."
    }

    # Vérifier que le compte n'existe pas déjà
    if (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue) {
        throw "Le compte '$Username' existe déjà."
    }

    try {
        # 1. Génération du mot de passe — CSPRNG compatible PS 5.1 et 7+
        $charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#%^&*-_=+"
        $bytes = New-Object byte[] $Length
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $rng.GetBytes($bytes)
        $rng.Dispose()
        $pwd = -join ($bytes | ForEach-Object { $charset[$_ % $charset.Length] })
        $secure = ConvertTo-SecureString $pwd -AsPlainText -Force

        # 2. Création du compte local
        New-LocalUser -Name $Username `
                      -Password $secure `
                      -FullName "Compte Admin $Username" `
                      -Description "Compte administrateur local créé par script" `
                      -PasswordNeverExpires | Out-Null

        # 3. Ajout au groupe administrateurs (par SID, indépendant de la langue)
        $adminGroup = Get-LocalGroup -SID "S-1-5-32-544"
        Add-LocalGroupMember -Group $adminGroup -Member $Username
        $Script:AdminAccount  = $Username
        $Script:AdminPassword = $pwd

        # Persistance IMMÉDIATE du credential sur disque : si le script crashe plus tard,
        # le mot de passe est déjà récupérable. Sans ça, perte définitive et poste inaccessible.
        # Stocké dans le même dossier que le rapport ($Script:LogPath) pour les retrouver côte-à-côte.
        $credDir  = Split-Path -Parent $Script:LogPath
        $credPath = Join-Path $credDir ("AdminCredential_{0}_{1}.txt" -f $Username, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $credContent = @"
=== Credential administrateur local ===
Créé par : win-cleaning.ps1
Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Machine  : $env:COMPUTERNAME
Username : $Username
Password : $pwd
========================================
"@
        Set-Content -LiteralPath $credPath -Value $credContent -Encoding UTF8
        $Script:AdminCredPath = $credPath

        Write-LogEntry -Message "Compte '$Username' créé. Mot de passe : $pwd" -Level SUCCESS
        Write-LogEntry -Message "Credential sauvegardé : $credPath" -Level INFO

        return $pwd
    }
    catch {
        Write-LogEntry -Message "New-AdminAccount : échec — $($_.Exception.Message)" -Level ERROR
        Add-Failure -StepLabel 'Étape 0 — Compte admin local' -Reason $_.Exception.Message
    }
}

function Get-FileWithProgress {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$OutFile,
        [string]$Label = "Téléchargement"
    )

    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.UserAgent = "PS"
    $resp = $req.GetResponse()
    $totalBytes = $resp.ContentLength
    $totalMo = [math]::Round($totalBytes / 1MB, 1)

    $stream = $resp.GetResponseStream()
    $fs = [System.IO.File]::Create($OutFile)

    $buffer = New-Object byte[] 1MB
    $readTotal = 0
    try {
        do {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            $fs.Write($buffer, 0, $read)
            $readTotal += $read
            $moLus = [math]::Round($readTotal / 1MB, 1)

            if ($totalBytes -gt 0) {
                $pct = [math]::Round(($readTotal / $totalBytes) * 100)
                Write-Progress -Activity $Label -Status "$moLus Mo / $totalMo Mo" -PercentComplete $pct
            }
            else {
                Write-Progress -Activity $Label -Status "$moLus Mo téléchargés"
            }
        } while ($read -gt 0)
    }
    finally {
        Write-Progress -Activity $Label -Completed
        $fs.Close(); $stream.Close(); $resp.Close()
    }
}

function Initialize-Winget {
    <#
    .SYNOPSIS
        Étape 0a — Garantit la présence de Winget (installe dépendances + winget si absent),
        puis met à jour les sources. Compatible Windows 10 / 11.
    .NOTES
        Cas tordu fréquent (vu en prod 2026-05-22) :
        Microsoft.DesktopAppInstaller est déjà installé pour AllUsers en version
        supérieure à celle d'aka.ms/getwinget → installer le bundle déclenche 0x80073D06
        ("version ultérieure déjà installée"). Même chose pour les VCLibs/UI.Xaml.
        En plus, même quand le paquet est là, son shim PATH n'est pas toujours propagé
        au compte courant (compte fraîchement créé / admin built-in).
        Ce code :
          1) détecte les déps déjà installées via Get-AppxPackage → évite le téléchargement
             ET évite -DependencyPath (cause de 0x80073D06)
          2) tolère 0x80073D06 sur le bundle (succès déguisé)
          3) localise winget.exe via Get-AppxPackage et l'ajoute au PATH session
             si Get-Command winget échoue
    #>
    [CmdletBinding()]
    param()

    $label = "Étape 0a — Init Winget"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    # --- Sous-fonctions internes ---
    function Test-WingetAvailable {
        $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
    }

    function Update-CurrentPath {
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [Environment]::GetEnvironmentVariable("Path", "User")
    }

    function Resolve-WingetFromAppx {
        # Si le paquet AppX est installé mais le shim PATH non propagé, retourne le dossier
        # contenant winget.exe pour qu'on l'ajoute manuellement au PATH session.
        try {
            $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue |
                   Sort-Object Version -Descending | Select-Object -First 1
            if (-not $pkg) { return $null }
            $exe = Join-Path $pkg.InstallLocation 'winget.exe'
            if (Test-Path -LiteralPath $exe) { return $pkg.InstallLocation }
        }
        catch { }
        return $null
    }

    # --- 1. Disponibilité initiale (PATH actuel → refresh PATH → fallback AppX) ---
    if (-not (Test-WingetAvailable)) { Update-CurrentPath }
    if (-not (Test-WingetAvailable)) {
        $wingetDir = Resolve-WingetFromAppx
        if ($wingetDir) {
            $env:Path = "$wingetDir;$env:Path"
            Write-LogEntry -Message "$label : winget localisé via AppX, ajouté au PATH session : $wingetDir" -Level INFO
        }
    }

    if (Test-WingetAvailable) {
        Write-LogEntry -Message "$label : winget déjà présent ($((winget --version) 2>$null))." -Level INFO
    }
    else {
        Write-LogEntry -Message "$label : winget absent, tentative d'installation." -Level WARN

        $installOk = Invoke-WithRetry -Label "$label (install)" -Action {
            $tmp  = $env:TEMP
            $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }

            # Tolère HRESULT 0x80073D06 (version ultérieure déjà installée → succès).
            function Add-AppxSafe {
                param([string]$Path)
                try {
                    Add-AppxPackage -Path $Path -ErrorAction Stop
                }
                catch {
                    if ($_.Exception.Message -match '0x80073D06' -or $_.Exception.Message -match 'ultérieure') {
                        Write-LogEntry -Message "$label : déjà présent en version >= (ignoré) — $Path" -Level INFO
                    }
                    else { throw }
                }
            }

            # Détection des déps déjà installées : on évite le download ET on évite
            # de les passer en -DependencyPath (sinon 0x80073D06 si la version système
            # est supérieure à celle qu'on téléchargerait).
            $vcExisting = Get-AppxPackage -AllUsers -Name 'Microsoft.VCLibs.140.00.UWPDesktop' -ErrorAction SilentlyContinue |
                          Sort-Object Version -Descending | Select-Object -First 1
            $xamlExisting = Get-AppxPackage -AllUsers -Name 'Microsoft.UI.Xaml.2.8' -ErrorAction SilentlyContinue |
                            Sort-Object Version -Descending | Select-Object -First 1

            $depPaths = @()
            $vcFile = $null; $xamlFile = $null

            if ($vcExisting) {
                Write-LogEntry -Message "$label : VCLibs déjà installé (v$($vcExisting.Version))." -Level INFO
            }
            else {
                $vcFile = Join-Path $tmp "vclibs.appx"
                Get-FileWithProgress -Uri "https://aka.ms/Microsoft.VCLibs.$arch.14.00.Desktop.appx" -OutFile $vcFile -Label "VCLibs"
                Add-AppxSafe -Path $vcFile
                $depPaths += $vcFile
            }

            if ($xamlExisting) {
                Write-LogEntry -Message "$label : UI.Xaml 2.8 déjà installé (v$($xamlExisting.Version))." -Level INFO
            }
            else {
                $xamlFile = Join-Path $tmp "xaml.appx"
                Get-FileWithProgress -Uri "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.$arch.appx" -OutFile $xamlFile -Label "UI.Xaml"
                Add-AppxSafe -Path $xamlFile
                $depPaths += $xamlFile
            }

            $bundleFile = Join-Path $tmp "winget.msixbundle"
            Get-FileWithProgress -Uri "https://aka.ms/getwinget" -OutFile $bundleFile -Label "Winget (~206 Mo)"

            try {
                if ($depPaths.Count -gt 0) {
                    Add-AppxPackage -Path $bundleFile -DependencyPath $depPaths -ErrorAction Stop
                }
                else {
                    # Toutes les déps déjà présentes → ne pas passer -DependencyPath.
                    Add-AppxPackage -Path $bundleFile -ErrorAction Stop
                }
            }
            catch {
                if ($_.Exception.Message -match '0x80073D06' -or $_.Exception.Message -match 'ultérieure') {
                    Write-LogEntry -Message "$label : bundle winget déjà présent en version >= (ignoré)." -Level INFO
                }
                else { throw }
            }

            # Cleanup ($vcFile/$xamlFile sont $null si le download a été skippé).
            foreach ($p in @($vcFile, $xamlFile, $bundleFile)) {
                if ($p -and (Test-Path -LiteralPath $p)) {
                    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Re-test : refresh PATH puis fallback AppX (le shim n'est pas toujours propagé).
        Update-CurrentPath
        if (-not (Test-WingetAvailable)) {
            $wingetDir = Resolve-WingetFromAppx
            if ($wingetDir) {
                $env:Path = "$wingetDir;$env:Path"
                Write-LogEntry -Message "$label : winget localisé via AppX post-install : $wingetDir" -Level INFO
            }
        }

        if (Test-WingetAvailable) {
            Write-LogEntry -Message "$label : winget installé avec succès." -Level SUCCESS
        }
        else {
            Add-Failure -StepLabel $label -Reason "Installation de winget échouée (dépendances ou contexte d'exécution)."
            return $false
        }
    }

    # --- 2. Mise à jour des sources ---
    $ok = Invoke-WithRetry -Label "$label (sources)" -Action {
        winget source update --accept-source-agreements | Out-Null
    }

    if (-not $ok) {
        Add-Failure -StepLabel $label -Reason "Mise à jour des sources Winget impossible."
        return $false
    }

    Write-LogEntry -Message "$label : terminé." -Level INFO
    return $true
}
 
function Install-PowerShell7 {
    <#
    .SYNOPSIS
        Étape 0b — Installation de PowerShell 7 via Winget (scope machine).
    .DESCRIPTION
        Conservée pour disposer de pwsh.exe sur le poste, mais la suite du script
        continue de s'exécuter sous PowerShell 5.1.
        Code -1978334957 toléré : update interdit / déjà géré par MSIX.
    #>
    [CmdletBinding()]
    param()

    Install-WingetPackage -Label "Étape 0b — PowerShell 7" `
                          -WingetId 'Microsoft.PowerShell' `
                          -DisplayName 'PowerShell 7' `
                          -DetectionPaths @((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')) `
                          -ExtraArgs @('--scope', 'machine') `
                          -ToleratedExitCodes @(0, -1978335189, -1978334957)
}
 
function Invoke-DebloatStep {
    <#
    .SYNOPSIS
        Étape 1 — Téléchargement et exécution silencieuse de Win11Debloat.
    #>
    [CmdletBinding()]
    param()
 
    $label = "Étape 1 — Win11Debloat"
    Write-LogEntry -Message "$label : démarrage" -Level INFO
 
    $debloatPath = Join-Path $Script:TempDir 'Win11Debloat.ps1'
 
    # Téléchargement de l'archive complète du repo (le script seul ne suffit pas :
    # il dépend des dossiers Scripts/, Appslists/, Config/ situés à côté de lui).
    $repoZipUrl  = 'https://github.com/Raphire/Win11Debloat/archive/refs/heads/master.zip'
    $zipPath     = Join-Path $Script:TempDir 'Win11Debloat.zip'
    $extractDir  = Join-Path $Script:TempDir 'Win11Debloat-master'
    $debloatPath = Join-Path $extractDir 'Win11Debloat.ps1'

    # Nettoyage préalable (idempotence).
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }

    # Téléchargement + extraction avec retry.
    $downloadOk = Invoke-WithRetry -Label "$label (download)" -Action {
        Invoke-WebRequest -Uri $repoZipUrl -OutFile $zipPath -UseBasicParsing
        if (-not (Test-Path -LiteralPath $zipPath)) { throw "ZIP non écrit." }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $Script:TempDir -Force
        if (-not (Test-Path -LiteralPath $debloatPath)) {
            throw "Win11Debloat.ps1 introuvable après extraction."
        }
    }

    if (-not $downloadOk) {
        Add-Failure -StepLabel $label -Reason "Téléchargement Win11Debloat impossible."
        return
    }

    # Exécution dans un sous-processus PowerShell isolé : évite que le Clear-Host
    # interne de Win11Debloat efface notre console parent.
    $runOk = Invoke-WithRetry -Label "$label (exec)" -Action {
        $psArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $debloatPath,
            '-Silent', '-RemoveApps', '-DisableTelemetry', '-DisableBing'
        )
        $proc = Start-Process -FilePath 'powershell.exe' `
                              -ArgumentList $psArgs `
                              -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "Win11Debloat ExitCode = $($proc.ExitCode)"
        }
    }

    if (-not $runOk) {
        Add-Failure -StepLabel $label -Reason "Exécution Win11Debloat en échec."
    }
}
 
function Get-AntivirusStatus {
    <#
    .SYNOPSIS
        Étape 2 — Audit des antivirus déclarés au Security Center.
    #>
    [CmdletBinding()]
    param()
 
    $label = "Étape 2 — Audit Antivirus"
    Write-LogEntry -Message "$label : démarrage" -Level INFO
 
    try {
        $products = Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop
 
        if (-not $products) {
            Write-LogEntry -Message "$label : aucun antivirus déclaré." -Level WARN
            return
        }
 
        foreach ($av in $products) {
            # Décodage du bitmask productState (référence : Microsoft Learn).
            $stateHex   = '{0:X6}' -f $av.productState
            $enabledBit = [Convert]::ToInt32($stateHex.Substring(2, 2), 16)
            $sigBit     = [Convert]::ToInt32($stateHex.Substring(4, 2), 16)
 
            $enabled = if ($enabledBit -band 0x10) { 'Enabled' } else { 'Disabled' }
            $sigs    = if ($sigBit -eq 0x00)        { 'UpToDate' } else { 'Outdated' }
 
            Write-LogEntry -Message ("$label : {0} | État : {1} | Signatures : {2}" -f $av.displayName, $enabled, $sigs) -Level SUCCESS
        }
    }
    catch {
        Add-Failure -StepLabel $label -Reason "Lecture SecurityCenter2 impossible : $($_.Exception.Message)"
        Write-LogEntry -Message "$label : échec — $($_.Exception.Message)" -Level ERROR
    }
}
 
function Install-GoogleChrome {
    <#
    .SYNOPSIS
        Étape 3 — Installation silencieuse de Google Chrome via Winget.
    #>
    [CmdletBinding()]
    param()

    Install-WingetPackage -Label "Étape 3 — Google Chrome" `
                          -WingetId 'Google.Chrome' `
                          -DisplayName 'Google Chrome' `
                          -DetectionPaths @(
                              (Join-Path $env:ProgramFiles        'Google\Chrome\Application\chrome.exe'),
                              (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
                          )
}

function Install-Microsoft365 {
    <#
    .SYNOPSIS
        Étape 6 — Installation de Microsoft 365 Apps for Entreprise via ODT.
    .DESCRIPTION
        Désinstallation conditionnelle d'Office existant (si détecté) via
        OfficeClickToRun, suppression des AppX Office, puis installation de
        Microsoft 365 Apps for Entreprise avec un configuration-install.xml généré.
    #>
    [CmdletBinding()]
    param()

    $label = "Étape 6 — Microsoft 365 Apps for Entreprise"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    # 6.a Désinstallation conditionnelle d'Office existant.
    # Détection élargie : Word/Excel ne suffisent pas (un poste avec uniquement Outlook,
    # Visio ou Project doit aussi être détecté). On combine markers fichiers + registre C2R.
    $officeBinaries = @('WINWORD.EXE','EXCEL.EXE','OUTLOOK.EXE','POWERPNT.EXE',
                        'MSACCESS.EXE','ONENOTE.EXE','VISIO.EXE','MSPUB.EXE','WINPROJ.EXE')
    $officeRoots = @(
        (Join-Path $env:ProgramFiles        'Microsoft Office\root\Office16'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16')
    )
    $officeMarkers = foreach ($root in $officeRoots) {
        foreach ($bin in $officeBinaries) { Join-Path $root $bin }
    }
    $officePresent = @($officeMarkers | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0

    # Fallback registre : couvre les installations atypiques (Visio standalone, Project, etc.).
    if (-not $officePresent) {
        $c2rReg = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
        if (Test-Path -LiteralPath $c2rReg) {
            $officePresent = $true
            Write-LogEntry -Message "$label : Office détecté via registre C2R (fallback)." -Level INFO
        }
    }

    if ($officePresent) {
        $c2rExe = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
        if (-not (Test-Path -LiteralPath $c2rExe)) {
            $c2rExe = Join-Path $env:ProgramFiles 'Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
        }
        if (Test-Path -LiteralPath $c2rExe) {
            Write-LogEntry -Message "$label : Office détecté, désinstallation via OfficeClickToRun." -Level INFO
            try {
                $proc = Start-Process -FilePath $c2rExe `
                                      -ArgumentList 'scenario=install', 'scenariosubtype=ARP', 'sourcetype=None', 'productstoremove=AllProducts', 'culture=fr-fr', 'DisplayLevel=False' `
                                      -Wait -PassThru
                $exitCode = $proc.ExitCode
                Write-LogEntry -Message "$label : ExitCode désinstallation = $exitCode" -Level INFO

                # OfficeClickToRun queue souvent le scénario en arrière-plan et retourne 0
                # avant que la désinstallation soit effective. On vérifie en re-testant les markers,
                # avec timeout. Si Office est toujours là après expiration, on abandonne M365
                # plutôt que d'installer par-dessus (cause classique de corruption).
                Write-LogEntry -Message "$label : attente de la fin effective de la désinstallation (timeout 10 min)..." -Level INFO
                $deadline = (Get-Date).AddMinutes(10)
                $stillThere = $true
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 15
                    $stillThere = @($officeMarkers | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
                    if (-not $stillThere) { break }
                }

                if ($stillThere) {
                    Add-Failure -StepLabel $label -Reason "Office encore présent 10 min après désinstallation (ExitCode=$exitCode). Redémarrage probablement requis — install M365 abandonnée."
                    Write-LogEntry -Message "$label : Office toujours détecté après désinstallation, install M365 ABANDONNÉE." -Level ERROR
                    return
                }
                Write-LogEntry -Message "$label : désinstallation Office confirmée." -Level SUCCESS
            }
            catch {
                Add-Failure -StepLabel $label -Reason "Désinstallation Office échouée : $($_.Exception.Message). Install M365 abandonnée pour éviter corruption."
                Write-LogEntry -Message "$label : désinstallation Office échouée — $($_.Exception.Message). Install M365 abandonnée." -Level ERROR
                return
            }
        }
        else {
            Add-Failure -StepLabel $label -Reason "Office détecté mais OfficeClickToRun.exe introuvable. Install M365 abandonnée."
            Write-LogEntry -Message "$label : Office détecté mais OfficeClickToRun.exe introuvable. Install M365 ABANDONNÉE." -Level ERROR
            return
        }
    }
    else {
        Write-LogEntry -Message "$label : aucune installation Office détectée, désinstallation skippée." -Level INFO
    }

    # 6.b Désinstallation des paquets AppX/MSIX correspondant aux 12 apps cibles.
    # (Access, Excel, OneDrive Groove, Skype for Business, OneDrive Desktop, OneNote,
    #  Outlook classic, Outlook new, PowerPoint, Publisher, Teams, Word).
    $appxPatterns = @(
        '*Microsoft.Office.Desktop*',          # Access, Excel, Word, PowerPoint, Outlook classic, Publisher
        '*Microsoft.Office.OneNote*',          # OneNote
        '*Microsoft.OneNote*',                 # OneNote variantes
        '*Microsoft.OneDriveSync*',            # OneDrive Groove
        '*Microsoft.SkypeForBusiness*',        # Skype for Business
        '*Microsoft.Teams*',                   # Teams
        '*MSTeams*',                           # Teams new
        '*Microsoft.OutlookForWindows*',       # Outlook new
        '*microsoft.windowscommunicationsapps*' # Outlook/Mail legacy
    )
    foreach ($pattern in $appxPatterns) {
        try {
            $packages = Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue
            foreach ($pkg in $packages) {
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                    Write-LogEntry -Message "$label : AppX supprimé — $($pkg.Name)" -Level SUCCESS
                }
                catch {
                    Write-LogEntry -Message "$label : échec suppression AppX $($pkg.Name) — $($_.Exception.Message)" -Level WARN
                }
            }
            $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                            Where-Object { $_.DisplayName -like $pattern }
            foreach ($prov in $provisioned) {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                    Write-LogEntry -Message "$label : AppX provisionné supprimé — $($prov.DisplayName)" -Level SUCCESS
                }
                catch {
                    Write-LogEntry -Message "$label : échec suppression provisioning $($prov.DisplayName) — $($_.Exception.Message)" -Level WARN
                }
            }
        }
        catch {
            Write-LogEntry -Message "$label : erreur pattern $pattern — $($_.Exception.Message)" -Level WARN
        }
    }
 
    # 6.c Installation de l'Office Deployment Tool.
    $odtOk = Invoke-WithRetry -Label "$label (ODT install)" -Action {
        $odtArgs = @('install', '--id', 'Microsoft.OfficeDeploymentTool',
                     '--silent', '--accept-source-agreements', '--accept-package-agreements')
        & winget @odtArgs | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
            throw "Winget ODT ExitCode = $LASTEXITCODE"
        }
    }
 
    if (-not $odtOk) {
        Add-Failure -StepLabel $label -Reason "Installation ODT en échec."
        return
    }
 
    # 6.d Localisation de setup.exe.
    $setupPath = Find-OdtSetup
    if (-not $setupPath) {
        Add-Failure -StepLabel $label -Reason "setup.exe ODT introuvable après installation."
        return
    }
    Write-LogEntry -Message "$label : ODT localisé à $setupPath" -Level INFO
 
    # 6.e Génération du XML de configuration.
    $configPath = Join-Path $Script:TempDir 'configuration-install.xml'
    $xmlContent = @'
<Configuration ID="aad1838d-35dd-4fd0-bae3-f6012e2b4113">
  <Info Description="https://www.net-lyon.com/"/>
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
'@
    Set-Content -LiteralPath $configPath -Value $xmlContent -Encoding UTF8
 
    # 6.f Lancement de l'installation avec surveillance de la progression.
    $installOk = Invoke-WithRetry -Label "$label (M365 install)" -MaxAttempts 1 -Action {
        # -PassThru sans -Wait : on récupère le handle pour surveiller en parallèle.
        $proc = Start-Process -FilePath $setupPath `
                              -ArgumentList '/configure', "`"$configPath`"" `
                              -PassThru -NoNewWindow
        if (-not $proc) { throw "Impossible de démarrer setup.exe." }

        # Boucle de surveillance (bloque jusqu'à la fin du process).
        Watch-OfficeInstallProgress -Process $proc -PollSeconds 1

        # ODT setup.exe délègue à OfficeClickToRun.exe puis se termine avec un ExitCode
        # parfois non nul/null alors que l'installation réussit. On valide donc par la
        # présence effective des binaires Office.
        $exitCode = $proc.ExitCode
        Write-LogEntry -Message "$label : ODT setup.exe ExitCode = $exitCode" -Level INFO

        $officeMarkers = @(
            (Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16\WINWORD.EXE'),
            (Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16\EXCEL.EXE')
        )
        $installed = $officeMarkers | Where-Object { Test-Path -LiteralPath $_ }

        if (-not $installed) {
            throw "Office non détecté après installation (ExitCode ODT = $exitCode)."
        }
        Write-LogEntry -Message "$label : Office détecté sur disque ($($installed.Count) binaire(s))." -Level SUCCESS
    }
 
    if (-not $installOk) {
        Add-Failure -StepLabel $label -Reason "Installation Microsoft 365 en échec."
    }
}

function Install-VLC {
    <#
    .SYNOPSIS
        Étape 4 — Installation silencieuse de VLC media player via Winget.
    #>
    [CmdletBinding()]
    param()

    Install-WingetPackage -Label "Étape 4 — VLC" `
                          -WingetId 'VideoLAN.VLC' `
                          -DisplayName 'VLC' `
                          -DetectionPaths @(
                              (Join-Path $env:ProgramFiles        'VideoLAN\VLC\vlc.exe'),
                              (Join-Path ${env:ProgramFiles(x86)} 'VideoLAN\VLC\vlc.exe')
                          )
}

function Install-FoxitReader {
    <#
    .SYNOPSIS
        Étape 5 — Installation silencieuse de Foxit PDF Reader via Winget.
    #>
    [CmdletBinding()]
    param()

    Install-WingetPackage -Label "Étape 5 — Foxit PDF Reader" `
                          -WingetId 'Foxit.FoxitReader' `
                          -DisplayName 'Foxit Reader' `
                          -DetectionPaths @(
                              (Join-Path $env:ProgramFiles        'Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe'),
                              (Join-Path ${env:ProgramFiles(x86)} 'Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe'),
                              (Join-Path $env:ProgramFiles        'Foxit Software\Foxit Reader\FoxitReader.exe'),
                              (Join-Path ${env:ProgramFiles(x86)} 'Foxit Software\Foxit Reader\FoxitReader.exe')
                          )
}

function Clear-TempArtifacts {
    <#
    .SYNOPSIS
        Étape 7 — Nettoyage des résidus du script dans $env:TEMP.
    .DESCRIPTION
        Supprime le script Win11Debloat, l'archive ZIP source, le dossier extrait
        Win11Debloat-master (plusieurs centaines de Mo) et le XML de configuration ODT.
    #>
    [CmdletBinding()]
    param()

    $label = "Étape 7 — Nettoyage"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    $targets = @(
        (Join-Path $Script:TempDir 'Win11Debloat.ps1'),
        (Join-Path $Script:TempDir 'Win11Debloat.zip'),
        (Join-Path $Script:TempDir 'Win11Debloat-master'),
        (Join-Path $Script:TempDir 'configuration-install.xml')
    )
    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) {
            try {
                Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction Stop
                Write-LogEntry -Message "$label : supprimé $t" -Level SUCCESS
            }
            catch {
                Write-LogEntry -Message "$label : impossible de supprimer $t — $($_.Exception.Message)" -Level WARN
            }
        }
    }
}
 
function Write-FinalReport {
    <#
    .SYNOPSIS
        Génère le rapport final dans %USERPROFILE% avec synthèse des échecs en en-tête.
    #>
    [CmdletBinding()]
    param()
 
    # Construction en deux passes via StringBuilder : synthèse d'abord, journal ensuite.
    $header = New-Object System.Text.StringBuilder
    [void]$header.AppendLine('========================================')
    [void]$header.AppendLine('RAPPORT D''EXÉCUTION — Préparation W11')
    [void]$header.AppendLine("Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$header.AppendLine("Machine : $env:COMPUTERNAME")
    [void]$header.AppendLine("Utilisateur : $env:USERNAME")
    [void]$header.AppendLine('========================================')
    [void]$header.AppendLine('')
    [void]$header.AppendLine('>>> COMPTE ADMINISTRATEUR LOCAL <<<')
    if ($Script:AdminAccount -and $Script:AdminPassword) {
        [void]$header.AppendLine("Username : $($Script:AdminAccount)")
        [void]$header.AppendLine("Password : $($Script:AdminPassword)")
        if ($Script:AdminCredPath) {
            [void]$header.AppendLine("Fichier  : $($Script:AdminCredPath)")
        }
        [void]$header.AppendLine('⚠ Notez le mot de passe puis supprimez ce rapport et le fichier credential.')
    }
    else {
        [void]$header.AppendLine('(non créé — voir synthèse des échecs ci-dessous)')
    }
    [void]$header.AppendLine('')
    [void]$header.AppendLine('>>> SYNTHÈSE DES ÉCHECS <<<')
    if ($Script:Failures.Count -eq 0) {
        [void]$header.AppendLine('Aucun échec détecté')
    }
    else {
        foreach ($f in $Script:Failures) { [void]$header.AppendLine($f) }
    }
    [void]$header.AppendLine('')
    [void]$header.AppendLine('========================================')
    [void]$header.AppendLine('JOURNAL DÉTAILLÉ')
    [void]$header.AppendLine('========================================')
 
    $fullReport = $header.ToString() + ($Script:LogEntries -join [Environment]::NewLine)
    Set-Content -LiteralPath $Script:LogPath -Value $fullReport -Encoding UTF8
 
    Write-Host ""
    Write-Host "Rapport écrit : $Script:LogPath" -ForegroundColor Green
}
 
#endregion ===========================================================================
 
#region ============================ MAIN ============================================
 
Write-LogEntry -Message "=== Début du traitement (PowerShell 5.1) ===" -Level INFO
Write-LogEntry -Message "Session administrateur confirmée." -Level INFO

# Ordre d'exécution : New-AdminAccount EN PREMIER (filet de sécurité critique).
# Si une étape plante non capturée plus tard, on a déjà créé un compte admin de secours
# avec mot de passe persisté sur disque.
$steps = @(
    @{ Name = 'New-AdminAccount';     Label = 'Étape 0  — Compte admin local' },
    @{ Name = 'Initialize-Winget';    Label = 'Étape 0a — Winget' },
    @{ Name = 'Install-PowerShell7';  Label = 'Étape 0b — PowerShell 7' },
    @{ Name = 'Invoke-DebloatStep';   Label = 'Étape 1  — Win11Debloat' },
    @{ Name = 'Get-AntivirusStatus';  Label = 'Étape 2  — Audit Antivirus' },
    @{ Name = 'Install-GoogleChrome'; Label = 'Étape 3  — Google Chrome' },
    @{ Name = 'Install-VLC';          Label = 'Étape 4  — VLC' },
    @{ Name = 'Install-FoxitReader';  Label = 'Étape 5  — Foxit PDF Reader' },
    @{ Name = 'Install-Microsoft365'; Label = 'Étape 6  — Microsoft 365' },
    @{ Name = 'Clear-TempArtifacts';  Label = 'Étape 7  — Nettoyage' }
)

# Chaque étape est isolée : une exception non capturée localement ne tue plus le script
# entier. Garantit que Write-FinalReport s'exécute toujours (donc rapport + credentials).
foreach ($step in $steps) {
    try {
        & $step.Name
    }
    catch {
        Write-LogEntry -Message "$($step.Label) : exception non gérée — $($_.Exception.Message)" -Level ERROR
        Add-Failure -StepLabel $step.Label -Reason "Exception non gérée : $($_.Exception.Message)"
    }
}

Write-LogEntry -Message "=== Fin du traitement ===" -Level INFO

Write-FinalReport

# Pause finale uniquement si on est en mode interactif (console utilisateur).
# Évite le blocage en exécution non-interactive (Task Scheduler, Intune, SCCM, SSH...).
if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    Write-Host ""
    Write-Host "Appuyez sur Entrée pour quitter..." -ForegroundColor Cyan
    try { Read-Host | Out-Null } catch { }
}

#endregion ===========================================================================

exit 0