#irm https://raw.githubusercontent.com/KevinBaptiste/windows-washing/refs/heads/main/washing-claude.ps1 -OutFile $HOME\Desktop\washing.ps1 | powershell -ExecutionPolicy Bypass -File $HOME\Desktop\washing.ps1
# Encodage : UTF-8 avec BOM (requis pour les accents sous PowerShell 5.1)
<#
.SYNOPSIS
    Script de préparation automatisée d'un poste Windows 11 (exécution monobloc PowerShell 5.1).
 
.DESCRIPTION
    Script "Plug & Play" lancé via clic-droit → "Exécuter avec PowerShell" :
      - Élévation administrateur automatique
      - Mise à jour des sources Winget
      - Installation de PowerShell 7 via Winget (conservée mais non utilisée pour la suite)
      - Debloat Windows 11 (Win11Debloat / Raphire)
      - Audit de l'antivirus actif
      - Installation Google Chrome, VLC, Foxit PDF Reader (via Winget)
      - Désinstallation d'Office existant (si détecté) puis installation de Microsoft 365 Apps for Entreprise FR via ODT
      - Nettoyage des fichiers temporaires
    Aucune interaction utilisateur n'est requise. Un rapport est généré sur le Bureau.

.EXAMPLE
    Clic-droit sur le fichier .ps1 → "Exécuter avec PowerShell".

.NOTES
    Auteur  : Kevin (BTST)
    Version : 1.2.0
    Date    : 2026-05-21
    Cible   : Windows 11 22H2+, PowerShell 5.1
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
$Script:DesktopPath     = [Environment]::GetFolderPath('Desktop')
$Script:LogPath         = Join-Path $Script:DesktopPath ("PrepW11_Rapport_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$Script:Win11DebloatUrl = 'https://raw.githubusercontent.com/Raphire/Win11Debloat/refs/heads/master/Win11Debloat.ps1'
 
#endregion ===========================================================================
 
#region ============================ LOGGING =========================================
 
# Collection d'événements journalisés ; les échecs sont synthétisés en tête de rapport.
$Script:LogEntries = New-Object System.Collections.Generic.List[string]
$Script:Failures   = New-Object System.Collections.Generic.List[string]
 
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

    # Dossier cible créé par ODT. On surveille les deux emplacements possibles.
    $officePaths = @(
        (Join-Path $env:ProgramFiles 'Microsoft Office'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office')
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

        Write-Host "Compte '$Username' créé et ajouté aux administrateurs." -ForegroundColor Green

        return $pwd
    }
    catch {
        Write-Error "Erreur lors de la création : $_"
    }
}
New-AdminAccount

function Initialize-Winget {
    <#
    .SYNOPSIS
        Étape 0a — Mise à jour des sources Winget.
    #>
    [CmdletBinding()]
    param()
 
    $label = "Étape 0a — Init Winget"
    Write-LogEntry -Message "$label : démarrage" -Level INFO
 
    $ok = Invoke-WithRetry -Label $label -Action {
        winget source update --accept-source-agreements | Out-Null
    }
 
    if (-not $ok) {
        Add-Failure -StepLabel $label -Reason "Mise à jour des sources Winget impossible."
    }
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

    # 6.a Désinstallation conditionnelle d'Office existant : on ne lance OfficeClickToRun
    #     que si une installation Office est effectivement présente sur disque.
    $officeMarkers = @(
        (Join-Path $env:ProgramFiles        'Microsoft Office\root\Office16\WINWORD.EXE'),
        (Join-Path $env:ProgramFiles        'Microsoft Office\root\Office16\EXCEL.EXE'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16\WINWORD.EXE'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16\EXCEL.EXE')
    )
    $officePresent = @($officeMarkers | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0

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
                Write-LogEntry -Message "$label : ExitCode désinstallation = $($proc.ExitCode)" -Level INFO
            }
            catch {
                Write-LogEntry -Message "$label : désinstallation Office non bloquante en échec — $($_.Exception.Message)" -Level WARN
            }
        }
        else {
            Write-LogEntry -Message "$label : Office détecté mais OfficeClickToRun.exe introuvable, désinstallation skippée." -Level WARN
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
        Génère le rapport final sur le Bureau avec synthèse des échecs en en-tête.
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
 
Initialize-Winget       # Étape 0a
Install-PowerShell7     # Étape 0b
Invoke-DebloatStep      # Étape 1
Get-AntivirusStatus     # Étape 2
Install-GoogleChrome    # Étape 3
Install-VLC             # Étape 4
Install-FoxitReader     # Étape 5
Install-Microsoft365    # Étape 6
Clear-TempArtifacts     # Étape 7
 
Write-LogEntry -Message "=== Fin du traitement ===" -Level INFO
 
Write-FinalReport
 
#endregion ===========================================================================
 
exit 0
