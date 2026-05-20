# Encodage : UTF-8 avec BOM (requis pour les accents sous PowerShell 5.1)
<#
.SYNOPSIS
    Script de préparation automatisée d'un poste Windows 11.

.DESCRIPTION
    Script "Plug & Play" exécutant en chaîne sous PowerShell 5.1 :
      - Élévation administrateur automatique
      - Installation de PowerShell 7 via Winget (conserve l'installation)
      - Debloat Windows 11 (Win11Debloat / Raphire)
      - Installation Microsoft 365 Famille FR via ODT
      - Audit de l'antivirus actif
      - Installation Google Chrome
      - Nettoyage des fichiers temporaires
    Aucune interaction utilisateur n'est requise. Un rapport est généré sur le Bureau.

.EXAMPLE
    Clic-droit sur le fichier .ps1 → "Exécuter avec PowerShell".

.NOTES
    Auteur  : Kevin (BTST)
    Version : 2.0.0
    Date    : 2026-05-20
    Cible   : Windows 11 22H2+, PowerShell 5.1
#>

# Politique d'erreur globale : toute exception non gérée stoppe l'étape courante.
$ErrorActionPreference = 'Stop'

# Forçage TLS 1.2 (nécessaire pour Invoke-WebRequest sous PS 5.1 sur certaines pages GitHub).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Test-AdminContext {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Si non élevé, on relance le script en RunAs en préservant son chemin d'origine.
if (-not (Test-AdminContext)) {
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

# Constantes globales
$Script:TempDir          = $env:TEMP
$Script:LogPath          = Join-Path ([Environment]::GetFolderPath('Desktop')) ("PrepW11_Rapport_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$Script:Win11DebloatUrl  = 'https://raw.githubusercontent.com/Raphire/Win11Debloat/refs/heads/master/Win11Debloat.ps1'

# Initialisation des listes pour le logging (Compatible PowerShell 5.1)
$Script:LogEntries = New-Object System.Collections.Generic.List[string]
$Script:Failures   = New-Object System.Collections.Generic.List[string]

#region ============================ LOGGING & HELPERS ===============================

function Write-LogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'SUCCESS', 'ERROR', 'WARN')] [string] $Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line      = "[{0}] [{1}] {2}" -f $timestamp, $Level.PadRight(7), $Message

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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StepLabel,
        [Parameter(Mandatory)] [string] $Reason
    )
    $Script:Failures.Add("[$StepLabel] : $Reason") | Out-Null
}

function Invoke-WithRetry {
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

    $found = Get-ChildItem -Path $env:ProgramFiles -Recurse -Filter 'setup.exe' -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -match 'OfficeDeploymentTool' } |
             Select-Object -First 1
    if ($found) { return $found.FullName }

    return $null
}

#endregion ===========================================================================

#region ============================ TRAITEMENT TRONC COMMUN ========================

Write-LogEntry -Message "=== Début du traitement (PowerShell 5.1) ===" -Level INFO

# --- ÉTAPE : INSTALLATION DE POWERSHELL 7 (Winget) ---
Write-LogEntry -Message "Mise à jour des sources Winget..." -Level INFO
try {
    winget source update --accept-source-agreements | Out-Null
}
catch {
    Write-LogEntry -Message "Mise à jour des sources Winget en échec ($($_.Exception.Message))." -Level WARN
}

$ps7InstallOk = Invoke-WithRetry -Label "Installation PowerShell 7" -Action {
    $wingetArgs = @(
        'install', '--id', 'Microsoft.PowerShell',
        '--silent', '--disable-interactivity', '--accept-source-agreements', '--accept-package-agreements',
        '--scope', 'machine'
    )
    & winget @wingetArgs | Out-Null
}
if (-not $ps7InstallOk) {
    Add-Failure -StepLabel "PowerShell 7" -Reason "L'installation en arrière-plan a échoué."
}


# --- ÉTAPE 1 : WIN11DEBLOAT ---
function Invoke-DebloatStep {
    $label  = "Étape 1 — Win11Debloat"
    $debloatPath = Join-Path $Script:TempDir 'Win11Debloat.ps1'

    $downloadOk = Invoke-WithRetry -Label "$label (téléchargement)" -Action {
        Invoke-WebRequest -Uri $Script:Win11DebloatUrl -OutFile $debloatPath -UseBasicParsing
        if (-not (Test-Path -LiteralPath $debloatPath)) { throw "Fichier non écrit." }
    }

    if (-not $downloadOk) {
        Add-Failure -StepLabel $label -Reason "Téléchargement Win11Debloat impossible."
        return
    }

    $runOk = Invoke-WithRetry -Label "$label (exécution)" -Action {
        # Exécution explicite dans l'instance PS 5.1 courante
        $output = & $debloatPath -Silent -RemoveApps -DisableTelemetry -DisableBing 2>&1 | Out-String
        $extractLength = [Math]::Min(500, $output.Length)
        Write-LogEntry -Message "Win11Debloat stdout (extrait) : $($output.Substring(0, $extractLength))" -Level INFO
    }

    if (-not $runOk) {
        Add-Failure -StepLabel $label -Reason "Exécution Win11Debloat en échec."
    }
}


# --- ÉTAPE 2 : MICROSOFT 365 FAMILLE FR ---
function Install-Microsoft365 {
    $label = "Étape 2 — Microsoft 365 Famille FR"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    # 2.a Nettoyage préventif des processus d'installation d'office qui pourraient être bloqués
    Write-LogEntry -Message "$label : Nettoyage des processus d'installation résiduels..." -Level INFO
    Get-Process -Name "setup", "OfficeClickToRun" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # Désinstallation des Office existants via OfficeClickToRun
    $c2rExe = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
    if (-not (Test-Path -LiteralPath $c2rExe)) {
        $c2rExe = Join-Path $env:ProgramFiles 'Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
    }
    if (Test-Path -LiteralPath $c2rExe) {
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

    # 2.b Installation de l'Office Deployment Tool via Winget
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

    # 2.c Localisation de setup.exe
    $setupPath = Find-OdtSetup
    if (-not $setupPath) {
        Add-Failure -StepLabel $label -Reason "setup.exe ODT introuvable après installation."
        return
    }

    # 2.d Génération du XML de configuration optimisé anti-blocage
    $configPath = Join-Path $Script:TempDir 'configuration-install.xml'
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
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Property Name="SharedComputerLicensing" Value="0" />
  <RemoveMSI />
</Configuration>
'@
    Set-Content -LiteralPath $configPath -Value $xmlContent -Encoding UTF8

    # 2.e Lancement de l'installation avec gestion de Timeout (Garantit l'absence de blocage infini)
    $installOk = Invoke-WithRetry -Label "$label (M365 install)" -Action {
        Write-LogEntry -Message "$label : Exécution de setup.exe /configure (Timeout max : 15 min)..." -Level INFO
        
        $proc = Start-Process -FilePath $setupPath `
                              -ArgumentList '/configure', "`"$configPath`"" `
                              -PassThru -NoNewWindow
        
        # Attente maximale de 900 secondes (15 minutes)
        $timeoutSec = 900
        $counter = 0
        while (-not $proc.HasExited -and $counter -lt $timeoutSec) {
            Start-Sleep -Seconds 2
            $counter += 2
        }

        if (-not $proc.HasExited) {
            Write-LogEntry -Message "$label : Timeout de 15 minutes atteint. Arrêt forcé du processus d'installation." -Level ERROR
            $proc | Stop-Process -Force
            throw "L'installation a dépassé le délai imparti de 15 minutes."
        }
        else {
            if ($proc.ExitCode -ne 0) { throw "ODT /configure ExitCode = $($proc.ExitCode)" }
        }
    }

    if (-not $installOk) {
        Add-Failure -StepLabel $label -Reason "Installation Microsoft 365 en échec ou hors délai."
    }
}


# --- ÉTAPE 3 : AUDIT ANTIVIRUS ---
function Get-AntivirusStatus {
    $label = "Étape 3 — Audit Antivirus"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    try {
        # Changement : Get-CimInstance fonctionne parfaitement sous PS 5.1
        $products = Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop

        if (-not $products) {
            Write-LogEntry -Message "$label : aucun antivirus déclaré." -Level WARN
            return
        }

        foreach ($av in $products) {
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


# --- ÉTAPE 4 : GOOGLE CHROME ---
function Install-GoogleChrome {
    $label = "Étape 4 — Google Chrome"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    $ok = Invoke-WithRetry -Label $label -Action {
        $args = @('install', '--id', 'Google.Chrome',
                  '--silent', '--disable-interactivity', '--accept-source-agreements', '--accept-package-agreements')
        $lastCode = $null
        & winget @args | Out-Null
        $lastCode = $Global:LASTEXITCODE
        if ($lastCode -ne 0 -and $lastCode -ne -1978335189) {
            throw "Winget Chrome ExitCode = $lastCode"
        }
    }

    if (-not $ok) {
        Add-Failure -StepLabel $label -Reason "Installation Google Chrome en échec."
    }
}


# --- ÉTAPE 5 : NETTOYAGE ---
function Clear-TempArtifacts {
    $label = "Étape 5 — Nettoyage"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    $targets = @(
        (Join-Path $Script:TempDir 'Win11Debloat.ps1'),
        (Join-Path $Script:TempDir 'configuration-install.xml')
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

# --- EXÉCUTION DU SEQUENCEUR ---
Invoke-DebloatStep
Install-Microsoft365
Get-AntivirusStatus
Install-GoogleChrome
Clear-TempArtifacts

Write-LogEntry -Message "=== Fin du traitement ===" -Level INFO

#endregion ===========================================================================

#region ============================ RAPPORT FINAL ===================================

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

# Sous PowerShell 5.1, l'encodage 'UTF8' génère nativement un fichier avec BOM (requis pour vos accents).
Set-Content -LiteralPath $Script:LogPath -Value $fullReport -Encoding UTF8

Write-Host ""
Write-Host "Rapport écrit : $Script:LogPath" -ForegroundColor Green

#endregion ===========================================================================

exit 0