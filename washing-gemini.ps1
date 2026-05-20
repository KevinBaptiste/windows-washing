# Encodage : UTF-8 avec BOM (requis pour les accents sous PowerShell 5.1)
<#
.SYNOPSIS
    Script de préparation automatisée d'un poste Windows 11.

.DESCRIPTION
    Script "Plug & Play" auto-extractible exécutant en chaîne :
      - Élévation administrateur automatique
      - Installation de PowerShell 7 via Winget
      - Bascule du traitement vers PS7
      - Debloat Windows 11 (Win11Debloat / Raphire)
      - Installation Microsoft 365 Famille FR via ODT
      - Audit de l'antivirus actif
      - Installation Google Chrome
      - Nettoyage et auto-destruction des fichiers temporaires
    Aucune interaction utilisateur n'est requise. Un rapport est généré sur le Bureau.

.EXAMPLE
    Clic-droit sur le fichier .ps1 → "Exécuter avec PowerShell".

.NOTES
    Auteur  : Kevin (BTST)
    Version : 1.0.1
    Date    : 2026-05-20
    Cible   : Windows 11 22H2+, PowerShell 5.1 minimum
#>

#region ============================== BOOTSTRAP (PS 5.1) ==============================

# Politique d'erreur globale : toute exception non gérée stoppe l'étape courante.
$ErrorActionPreference = 'Stop'

# Forçage TLS 1.2 (nécessaire pour Invoke-WebRequest sous PS 5.1 sur certaines pages GitHub).
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
$Script:TempDir          = $env:TEMP
$Script:LogPath          = Join-Path ([Environment]::GetFolderPath('Desktop')) ("PrepW11_Rapport_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$Script:Win11DebloatUrl  = 'https://raw.githubusercontent.com/Raphire/Win11Debloat/main/Win11Debloat.ps1'
$Script:Pwsh7Path        = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'

Write-Host "[BOOTSTRAP] Session administrateur confirmée." -ForegroundColor Yellow
Write-Host "[BOOTSTRAP] Mise à jour des sources Winget..." -ForegroundColor Yellow

# Mise à jour des sources Winget (non bloquant en cas d'échec partiel).
try {
    winget source update --accept-source-agreements | Out-Null
    Write-Host "[BOOTSTRAP] Sources Winget mises à jour." -ForegroundColor Green
}
catch {
    Write-Host "[BOOTSTRAP] Avertissement : mise à jour des sources Winget en échec ($($_.Exception.Message))." -ForegroundColor Red
}

# Installation de PowerShell 7 (idempotent : Winget skip si déjà installé).
Write-Host "[BOOTSTRAP] Installation de PowerShell 7..." -ForegroundColor Yellow
try {
    $wingetArgs = @(
        'install', '--id', 'Microsoft.PowerShell',
        '--silent', '--disable-interactivity', '--accept-source-agreements', '--accept-package-agreements',
        '--scope', 'machine'
    )
    & winget @wingetArgs | Out-Null
    Write-Host "[BOOTSTRAP] PowerShell 7 installé (ou déjà présent)." -ForegroundColor Green
}
catch {
    Write-Host "[BOOTSTRAP] Échec installation PS7 : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Vérification de la présence physique de pwsh.exe (chemin absolu, jamais via PATH).
if (-not (Test-Path -LiteralPath $Script:Pwsh7Path)) {
    Write-Host "[BOOTSTRAP] pwsh.exe introuvable à l'emplacement attendu : $Script:Pwsh7Path" -ForegroundColor Red
    exit 1
}

#endregion ===========================================================================

#region ========================== PASSAGE DE RELAIS PS7 =============================

# Génération du script PS7 dans $env:TEMP via here-string.
$ps7ScriptPath = Join-Path $Script:TempDir ("PrepW11_PS7_{0}.ps1" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))

$ps7Body = @'
<#
.SYNOPSIS
    Corps principal exécuté sous PowerShell 7.
.DESCRIPTION
    Réalise les étapes 1 à 5 du cahier des charges : Win11Debloat, Microsoft 365 FR,
    audit antivirus, Google Chrome, nettoyage.
.PARAMETER LogPath
    Chemin complet du rapport texte sur le Bureau.
.PARAMETER Win11DebloatUrl
    URL brute du script Win11Debloat.ps1.
.PARAMETER TempDir
    Répertoire temporaire de travail.
.NOTES
    Auteur  : Kevin (BTST)
    Version : 1.0.1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $LogPath,
    [Parameter(Mandatory)] [string] $Win11DebloatUrl,
    [Parameter(Mandatory)] [string] $TempDir,
    [Parameter(Mandatory)] [string] $SelfPath
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#region ============================ LOGGING =========================================

# Collection d'événements journalisés ; les échecs sont synthétisés en tête de rapport.
$Script:LogEntries = [System.Collections.Generic.List[string]]::new()
$Script:Failures   = [System.Collections.Generic.List[string]]::new()

function Write-LogEntry {
    <#
    .SYNOPSIS
        Écrit une entrée journalisée à la fois en console (colorée) et en mémoire (rapport).
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
        Localise setup.exe de l'Office Deployment Tool dans Program Files.
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

#endregion ===========================================================================

#region ============================ STEPS ===========================================

function Invoke-DebloatStep {
    <#
    .SYNOPSIS
        Étape 1 — Téléchargement et exécution silencieuse de Win11Debloat.
    #>
    [CmdletBinding()]
    param()

    $label  = "Étape 1 — Win11Debloat"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    $debloatPath = Join-Path $TempDir 'Win11Debloat.ps1'

    # Téléchargement avec retry.
    $downloadOk = Invoke-WithRetry -Label "$label (download)" -Action {
        Invoke-WebRequest -Uri $Win11DebloatUrl -OutFile $debloatPath -UseBasicParsing
        if (-not (Test-Path -LiteralPath $debloatPath)) { throw "Fichier non écrit." }
    }

    if (-not $downloadOk) {
        Add-Failure -StepLabel $label -Reason "Téléchargement Win11Debloat impossible."
        return
    }

    # Exécution silencieuse avec capture du flux.
    $runOk = Invoke-WithRetry -Label "$label (exec)" -Action {
        $output = & $debloatPath -Silent -RemoveApps -DisableTelemetry -DisableBing 2>&1 | Out-String
        $extractLength = [Math]::Min(500, $output.Length)
        Write-LogEntry -Message "Win11Debloat stdout (extrait) : $($output.Substring(0, $extractLength))" -Level INFO
    }

    if (-not $runOk) {
        Add-Failure -StepLabel $label -Reason "Exécution Win11Debloat en échec."
    }
}

function Install-Microsoft365 {
    <#
    .SYNOPSIS
        Étape 2 — Installation de Microsoft 365 Famille FR via ODT.
    #>
    [CmdletBinding()]
    param()

    $label = "Étape 2 — Microsoft 365 Famille FR"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    # 2.a Désinstallation des installations Office existantes (best-effort).
    $c2rExe = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
    if (-not (Test-Path -LiteralPath $c2rExe)) {
        $c2rExe = Join-Path $env:ProgramFiles 'Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
    }
    if (Test-Path -LiteralPath $c2rExe) {
        Write-LogEntry -Message "$label : désinstallation des Office existants via OfficeClickToRun." -Level INFO
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
        Write-LogEntry -Message "$label : aucun OfficeClickToRun détecté, pas d'Office à désinstaller." -Level INFO
    }

    # 2.b Installation de l'Office Deployment Tool.
    $odtOk = Invoke-WithRetry -Label "$label (ODT install)" -Action {
        $args = @('install', '--id', 'Microsoft.OfficeDeploymentTool',
                  '--silent', '--disable-interactivity', '--accept-source-agreements', '--accept-package-agreements')
        $lastCode = $null
        & winget @args | Out-Null
        $lastCode = $Global:LASTEXITCODE
        if ($lastCode -ne 0) { throw "Winget ODT ExitCode = $lastCode" }
    }

    if (-not $odtOk) {
        Add-Failure -StepLabel $label -Reason "Installation ODT en échec."
        return
    }

    # 2.c Localisation de setup.exe.
    $setupPath = Find-OdtSetup
    if (-not $setupPath) {
        Add-Failure -StepLabel $label -Reason "setup.exe ODT introuvable après installation."
        return
    }
    Write-LogEntry -Message "$label : ODT localisé à $setupPath" -Level INFO

    # 2.d Génération du XML de configuration.
    $configPath = Join-Path $TempDir 'configuration-install.xml'
    $xmlContent = @'
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="O365HomePremRetail">
      <Language ID="fr-fr" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
    </Product>
  </Add>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
  <RemoveMSI />
</Configuration>
'@
    Set-Content -LiteralPath $configPath -Value $xmlContent -Encoding UTF8

    # 2.e Lancement de l'installation.
    $installOk = Invoke-WithRetry -Label "$label (M365 install)" -Action {
        $proc = Start-Process -FilePath $setupPath `
                              -ArgumentList '/configure', "`"$configPath`"" `
                              -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) { throw "ODT /configure ExitCode = $($proc.ExitCode)" }
    }

    if (-not $installOk) {
        Add-Failure -StepLabel $label -Reason "Installation Microsoft 365 en échec."
    }
}

function Get-AntivirusStatus {
    <#
    .SYNOPSIS
        Étape 3 — Audit des antivirus déclarés au Security Center via masques binaires natifs.
    #>
    [CmdletBinding()]
    param()

    $label = "Étape 3 — Audit Antivirus"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    try {
        $products = Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop

        if (-not $products) {
            Write-LogEntry -Message "$label : aucun antivirus déclaré." -Level WARN
            return
        }

        foreach ($av in $products) {
            # Utilisation de masques binaires directs (-band) pour éviter les erreurs de Substring sur productState
            $enabled = if ($av.productState -band 0x1000) { 'Enabled' } else { 'Disabled' }
            $sigs    = if (($av.productState -band 0xFF) -eq 0) { 'UpToDate' } else { 'Outdated' }

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
        Étape 4 — Installation silencieuse de Google Chrome via Winget.
    #>
    [CmdletBinding()]
    param()

    $label = "Étape 4 — Google Chrome"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    $ok = Invoke-WithRetry -Label $label -Action {
        $args = @('install', '--id', 'Google.Chrome',
                  '--silent', '--disable-interactivity', '--accept-source-agreements', '--accept-package-agreements')
        $lastCode = $null
        & winget @args | Out-Null
        $lastCode = $Global:LASTEXITCODE
        # Winget renvoie 0 si installé, -1978335189 (ou 0x8A15002B) si déjà présent : on tolère.
        if ($lastCode -ne 0 -and $lastCode -ne -1978335189) {
            throw "Winget Chrome ExitCode = $lastCode"
        }
    }

    if (-not $ok) {
        Add-Failure -StepLabel $label -Reason "Installation Google Chrome en échec."
    }
}

function Clear-TempArtifacts {
    <#
    .SYNOPSIS
        Étape 5 — Nettoyage des résidus du script.
    #>
    [CmdletBinding()]
    param()

    $label = "Étape 5 — Nettoyage"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    $targets = @(
        (Join-Path $TempDir 'Win11Debloat.ps1'),
        (Join-Path $TempDir 'configuration-install.xml')
    )
    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) {
            try {
                Remove-Item -LiteralPath $t -Force -ErrorAction Stop
                Write-LogEntry -Message "$label : supprimé $t" -Level SUCCESS
            }
            catch {
                Write-LogEntry -Message "$label : impossible de supprimer $t — $($_.Exception.Message)" -Level WARN
            }
        }
    }
}

#endregion ===========================================================================

#region ============================ MAIN ============================================

Write-LogEntry -Message "=== Début du traitement PS7 ===" -Level INFO

Invoke-DebloatStep
Install-Microsoft365
Get-AntivirusStatus
Install-GoogleChrome
Clear-TempArtifacts

Write-LogEntry -Message "=== Fin du traitement PS7 ===" -Level INFO

# --- Écriture du rapport final en deux passes ---
$header = [System.Text.StringBuilder]::new()
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
Set-Content -LiteralPath $LogPath -Value $fullReport -Encoding UTF8

Write-Host ""
Write-Host "Rapport écrit : $LogPath" -ForegroundColor Green

# --- Auto-suppression du sous-script PS7 ---
# Utilisation de ping à la place de timeout pour éviter les blocages en arrière-plan sans flux d'entrée
$selfDelete = "ping 1.2.3.4 -n 1 -w 5000 >nul & del /f /q `"$SelfPath`""
Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $selfDelete -WindowStyle Hidden

#endregion ===========================================================================
'@

# Écriture du script PS7 en UTF-8 avec BOM
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($ps7ScriptPath, $ps7Body, $utf8Bom)

Write-Host "[BOOTSTRAP] Script PS7 écrit : $ps7ScriptPath" -ForegroundColor Gray
Write-Host "[BOOTSTRAP] Lancement de PowerShell 7..." -ForegroundColor Yellow

# Lancement de PS7 via chemin absolu, en synchrone, sans profil ni interaction.
$pwshArgs = @(
    '-NoProfile', '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', $ps7ScriptPath,
    '-LogPath',         $Script:LogPath,
    '-Win11DebloatUrl', $Script:Win11DebloatUrl,
    '-TempDir',         $Script:TempDir,
    '-SelfPath',        $ps7ScriptPath
)

try {
    $ps7Proc = Start-Process -FilePath $Script:Pwsh7Path -ArgumentList $pwshArgs -Wait -PassThru -NoNewWindow
    Write-Host "[BOOTSTRAP] PS7 terminé avec ExitCode = $($ps7Proc.ExitCode)" -ForegroundColor Green
}
catch {
    Write-Host "[BOOTSTRAP] Échec du lancement PS7 : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

#endregion ===========================================================================

# Fermeture propre de la session PS 5.1.
exit 0