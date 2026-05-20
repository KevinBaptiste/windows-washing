# Encodage : UTF-8 avec BOM (requis pour les accents sous PowerShell 5.1)
<#
.SYNOPSIS
    Script de préparation automatisée d'un poste Windows 11 (exécution monobloc PowerShell 5.1).
 
.DESCRIPTION
    Script "Plug & Play" lancé via clic-droit → "Exécuter avec PowerShell" :
      - Élévation administrateur automatique
      - Installation de PowerShell 7 via Winget (conservée mais non utilisée pour la suite)
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
    Version : 1.1.0
    Date    : 2026-05-20
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
        Surveille la progression de l'installation Office par mesure de la taille du dossier cible.
    .DESCRIPTION
        Tant que le process ODT tourne, la fonction mesure périodiquement la taille de
        C:\Program Files\Microsoft Office et affiche une barre Write-Progress.
        Taille finale estimée : 4 Go pour M365 Famille FR (Word, Excel, PowerPoint, Outlook,
        OneNote, Publisher, Access) hors Groove/Lync exclus.
    .PARAMETER Process
        Objet System.Diagnostics.Process renvoyé par Start-Process -PassThru.
    .PARAMETER EstimatedSizeMB
        Taille finale estimée en Mo (défaut : 4000).
    .PARAMETER PollSeconds
        Intervalle entre deux mesures (défaut : 5s).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [int] $EstimatedSizeMB = 4000,
        [int] $PollSeconds     = 5
    )

    # Dossier cible créé par ODT. On surveille les deux emplacements possibles.
    $officePaths = @(
        (Join-Path $env:ProgramFiles 'Microsoft Office'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office')
    )

    $startTime = Get-Date

    while (-not $Process.HasExited) {
        # Somme des tailles des deux emplacements (l'un des deux peut ne pas exister).
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

        $currentMB = [math]::Round($totalBytes / 1MB, 0)
        $percent   = [math]::Min(99, [math]::Round(($currentMB / $EstimatedSizeMB) * 100, 0))
        $elapsed   = (Get-Date) - $startTime
        $elapsedFmt = "{0:hh\:mm\:ss}" -f $elapsed

        Write-Progress -Activity "Installation Microsoft 365 Famille FR" `
                       -Status ("{0} Mo / ~{1} Mo  |  Écoulé : {2}" -f $currentMB, $EstimatedSizeMB, $elapsedFmt) `
                       -PercentComplete $percent

        Start-Sleep -Seconds $PollSeconds
    }

    # Fermeture propre de la barre.
    Write-Progress -Activity "Installation Microsoft 365 Famille FR" -Completed
}

#endregion ===========================================================================
 
#region ============================ STEPS ===========================================
 
function Initialize-Winget {
    <#
    .SYNOPSIS
        Étape 0a — Mise à jour des sources Winget.
    #>
    [CmdletBinding()]
    param()
 
    $label = "Étape 0 — Init Winget"
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
        Étape 0b — Installation de PowerShell 7 via Winget.
    .DESCRIPTION
        Vérifie d'abord la présence de pwsh.exe (chemin standard d'installation machine).
        Si déjà présent, l'installation est skippée. Sinon, installation silencieuse via Winget.
        L'installation est conservée pour disposer de pwsh.exe sur le poste, mais la suite
        du script continue de s'exécuter sous PowerShell 5.1.
    #>
    [CmdletBinding()]
    param()

    $label = "Étape 0 — PowerShell 7"
    Write-LogEntry -Message "$label : démarrage" -Level INFO

    # Vérification préalable : pwsh.exe présent au chemin standard d'installation machine ?
    $pwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $pwshPath) {
        try {
            # Récupération de la version pour log informatif.
            $versionOutput = & $pwshPath -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            Write-LogEntry -Message "$label : PowerShell $versionOutput déjà installé, installation skippée." -Level SUCCESS
        }
        catch {
            Write-LogEntry -Message "$label : PowerShell 7 déjà installé (version non lisible), installation skippée." -Level SUCCESS
        }
        return
    }

    Write-LogEntry -Message "$label : PowerShell 7 absent, installation via Winget." -Level INFO

    $ok = Invoke-WithRetry -Label $label -Action {
        $wingetArgs = @(
            'install', '--id', 'Microsoft.PowerShell',
            '--silent', '--accept-source-agreements', '--accept-package-agreements',
            '--scope', 'machine'
        )
        & winget @wingetArgs | Out-Null
        # Codes tolérés : 0 (OK), -1978335189 (déjà installé), -1978334957 (update interdit / déjà géré par MSIX).
        $toleratedCodes = @(0, -1978335189, -1978334957)
        if ($toleratedCodes -notcontains $LASTEXITCODE) {
            throw "Winget PowerShell ExitCode = $LASTEXITCODE"
        }
    }

    if (-not $ok) {
        Add-Failure -StepLabel $label -Reason "Installation PowerShell 7 en échec."
    }
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

    # Exécution silencieuse depuis le dossier extrait (dépendances trouvées via $PSScriptRoot).
    # Win11Debloat écrit des messages informatifs sur stderr (registre, MSIX) qui, combinés
    # à $ErrorActionPreference = 'Stop', sont levés comme exceptions. On isole donc l'appel
    # avec un ErrorActionPreference local à 'Continue' pour ne pas faire échouer l'étape.
    $runOk = Invoke-WithRetry -Label "$label (exec)" -Action {
        $previousEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # Redirection complète des flux ; les "erreurs" non terminantes sont capturées comme texte.
            $output = & $debloatPath -Silent -RemoveApps -DisableTelemetry -DisableBing *>&1 | Out-String

            # Vérification du code de sortie réel du script (et non du flux stderr).
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                throw "Win11Debloat ExitCode = $LASTEXITCODE"
            }

            if (-not [string]::IsNullOrWhiteSpace($output)) {
                $extract = $output.Substring(0, [Math]::Min(500, $output.Length))
                Write-LogEntry -Message "Win11Debloat stdout (extrait) : $extract" -Level INFO
            }
        }
        finally {
            $ErrorActionPreference = $previousEAP
        }
    }

    if (-not $runOk) {
        Add-Failure -StepLabel $label -Reason "Exécution Win11Debloat en échec."
    }
}
 
function Get-AntivirusStatus {
    <#
    .SYNOPSIS
        Étape 3 — Audit des antivirus déclarés au Security Center.
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
        Étape 4 — Installation silencieuse de Google Chrome via Winget.
    #>
    [CmdletBinding()]
    param()
 
    $label = "Étape 4 — Google Chrome"
    Write-LogEntry -Message "$label : démarrage" -Level INFO
 
    $ok = Invoke-WithRetry -Label $label -Action {
        $chromeArgs = @('install', '--id', 'Google.Chrome',
                        '--silent', '--accept-source-agreements', '--accept-package-agreements')
        & winget @chromeArgs | Out-Null
        # Winget : 0 = installé, -1978335189 = déjà présent : on tolère.
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
            throw "Winget Chrome ExitCode = $LASTEXITCODE"
        }
    }
 
    if (-not $ok) {
        Add-Failure -StepLabel $label -Reason "Installation Google Chrome en échec."
    }
}
<
function Install-Microsoft365 {
    <#
    .SYNOPSIS
        Étape 2 — Installation de Microsoft 365 Famille FR via ODT.
    .DESCRIPTION
        Désinstallation des Office existants via OfficeClickToRun, puis installation
        de M365 Famille FR avec un fichier configuration-install.xml généré en mémoire.
    #>
    [CmdletBinding()]
    param()
 
    $label = "Étape 2 — Microsoft 365 Famille FR"
    Write-LogEntry -Message "$label : démarrage" -Level INFO
 
    # 2.a Désinstallation des installations Office existantes (best-effort, non bloquant).
    $c2rExe = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
    if (-not (Test-Path -LiteralPath $c2rExe)) {
        $c2rExe = Join-Path $env:ProgramFiles 'Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
    }
    if (Test-Path -LiteralPath $c2rExe) {
        Write-LogEntry -Message "$label : désinstallation Office via OfficeClickToRun." -Level INFO
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
        Write-LogEntry -Message "$label : aucun OfficeClickToRun détecté, rien à désinstaller." -Level INFO
    }
 
    # 2.b Installation de l'Office Deployment Tool.
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
 
    # 2.c Localisation de setup.exe.
    $setupPath = Find-OdtSetup
    if (-not $setupPath) {
        Add-Failure -StepLabel $label -Reason "setup.exe ODT introuvable après installation."
        return
    }
    Write-LogEntry -Message "$label : ODT localisé à $setupPath" -Level INFO
 
    # 2.d Génération du XML de configuration.
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
  <RemoveMSI />
</Configuration>
'@
    Set-Content -LiteralPath $configPath -Value $xmlContent -Encoding UTF8
 
# 2.e Lancement de l'installation avec surveillance de la progression.
    $installOk = Invoke-WithRetry -Label "$label (M365 install)" -Action {
        # -PassThru sans -Wait : on récupère le handle pour surveiller en parallèle.
        $proc = Start-Process -FilePath $setupPath `
                              -ArgumentList '/configure', "`"$configPath`"" `
                              -PassThru -NoNewWindow
        if (-not $proc) { throw "Impossible de démarrer setup.exe." }

        # Boucle de surveillance (bloque jusqu'à la fin du process).
        Watch-OfficeInstallProgress -Process $proc -EstimatedSizeMB 4000 -PollSeconds 5

        # Vérification finale du code de sortie.
        if ($proc.ExitCode -ne 0) { throw "ODT /configure ExitCode = $($proc.ExitCode)" }
    }
 
    if (-not $installOk) {
        Add-Failure -StepLabel $label -Reason "Installation Microsoft 365 en échec."
    }
}
 
function Clear-TempArtifacts {
    <#
    .SYNOPSIS
        Étape 5 — Nettoyage des résidus du script dans $env:TEMP.
    #>
    [CmdletBinding()]
    param()
 
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
 
Initialize-Winget
Install-PowerShell7
Invoke-DebloatStep
Install-Microsoft365
Get-AntivirusStatus
Install-GoogleChrome
Clear-TempArtifacts
 
Write-LogEntry -Message "=== Fin du traitement ===" -Level INFO
 
Write-FinalReport
 
#endregion ===========================================================================
 
exit 0
