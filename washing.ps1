<#
.SYNOPSIS
    Préparation automatisée d'un poste Windows.
.DESCRIPTION
    1. Installe PowerShell 7 (dernière version)
    2. Lance Win11Debloat (Raphire)
    3. Désinstalle toute version d'Office puis installe Microsoft 365 Apps (fr-FR)
    4. Vérifie les antivirus
    5. Installe Google Chrome
.NOTES
    Exécution : irm <raw_url> -OutFile washing.ps1; .\washing.ps1
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
 
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
 
# ─── Variables globales ───────────────────────────────────────────────────────
 
$Script:LogFile  = Join-Path $env:TEMP "washing_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$Script:WorkDir  = Join-Path $env:TEMP "washing_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$Script:StepNum  = 0
$Script:TotalStep = 5
New-Item -ItemType Directory -Path $Script:WorkDir -Force | Out-Null
 
# ─── Helpers ──────────────────────────────────────────────────────────────────
 
function Write-Log {
    param([string]$Level, [string]$Msg, [ConsoleColor]$Color = 'White')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Msg
    Add-Content -Path $Script:LogFile -Value $line
    Write-Host $line -ForegroundColor $Color
}
 
function Write-Step {
    param([string]$Msg)
    $Script:StepNum++
    Write-Host ""
    Write-Log 'STEP' "[$Script:StepNum/$Script:TotalStep] $Msg" Cyan
}
 
function Write-OK   { param($Msg) Write-Log 'OK  ' "  $Msg" Green }
function Write-Skip { param($Msg) Write-Log 'SKIP' "  $Msg" DarkGray }
function Write-Fail { param($Msg) Write-Log 'FAIL' "  $Msg" Red }
function Write-Warn { param($Msg) Write-Log 'WARN' "  $Msg" Yellow }
function Write-Info { param($Msg) Write-Log 'INFO' "  $Msg" Gray }
 
function Confirm-Action {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    $hint = if ($DefaultYes) { '[O/n]' } else { '[o/N]' }
    $reply = (Read-Host "$Prompt $hint").Trim().ToLower()
    if ([string]::IsNullOrEmpty($reply)) { return $DefaultYes }
    return $reply -in @('o', 'oui', 'y', 'yes')
}
 
function Get-SystemArch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { 'arm64' }
        'AMD64' { 'x64'   }
        default { 'x86'   }
    }
}
 
function Test-InternetAccess {
    try {
        $req = [Net.HttpWebRequest]::Create('https://www.microsoft.com')
        $req.Method = 'HEAD'; $req.Timeout = 5000
        $req.GetResponse().Close()
        return $true
    } catch { return $false }
}
 
function Invoke-SafeDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Label = (Split-Path $Url -Leaf),
        [int]$TimeoutSec = 300
    )
    Write-Info "Téléchargement : $Label"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec $TimeoutSec
        if (-not (Test-Path $Destination) -or (Get-Item $Destination).Length -eq 0) {
            throw "Fichier téléchargé vide ou manquant."
        }
    } catch {
        throw "Échec téléchargement de $Label : $_"
    }
}
 
function Invoke-Process {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList,
        [int[]]$SuccessCodes = @(0)
    )
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -notin $SuccessCodes) {
        throw "Process '$FilePath' a retourné le code $($p.ExitCode)."
    }
    return $p.ExitCode
}
 
function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    try { & $Action }
    catch { Write-Fail "Étape '$Name' : $($_.Exception.Message)" }
}
 
# ─── Étape 1 : PowerShell 7 ───────────────────────────────────────────────────
 
function Step-PowerShell7 {
    Write-Step "PowerShell 7 — dernière version"
 
    if (-not (Test-InternetAccess)) { Write-Warn "Pas d'accès Internet."; return }
 
    $rel       = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -TimeoutSec 10
    $latestVer = [version]$rel.tag_name.TrimStart('v')
    $arch      = Get-SystemArch
 
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwshCmd) {
        $currentVer = [version]$pwshCmd.Version.ToString()
        if ($currentVer -ge $latestVer) {
            Write-Skip "PowerShell $currentVer déjà à jour."
            return
        }
        Write-Info "Version actuelle : $currentVer → cible : $latestVer"
    }
 
    if (-not (Confirm-Action "  Installer PowerShell $latestVer ($arch) ?")) {
        Write-Skip "Étape ignorée."; return
    }
 
    $asset = $rel.assets | Where-Object { $_.name -like "*win-$arch.msi" } | Select-Object -First 1
    if (-not $asset) { throw "Aucun MSI trouvé pour l'architecture $arch." }
 
    $msi = Join-Path $Script:WorkDir $asset.name
    Invoke-SafeDownload -Url $asset.browser_download_url -Destination $msi -Label $asset.name
    Write-Info "Installation MSI…"
    Invoke-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$msi`"", '/quiet', '/norestart') -SuccessCodes @(0, 3010)
    Write-OK "PowerShell $latestVer installé (relancer le terminal)."
}
 
# ─── Étape 2 : Win11Debloat ───────────────────────────────────────────────────
 
function Step-Debloat {
    Write-Step "Raphire / Win11Debloat"
 
    Write-Host "    [1] Mode automatique (CustomList.txt)"
    Write-Host "    [2] Mode interactif"
    Write-Host "    [0] Ignorer"
    $mode = Read-Host "  Choix"
 
    if ($mode -notin @('1', '2')) { Write-Skip "Étape ignorée."; return }
    if (-not (Test-InternetAccess)) { Write-Warn "Pas d'accès Internet."; return }
 
    $zip    = Join-Path $Script:WorkDir 'Win11Debloat.zip'
    $extract = Join-Path $Script:WorkDir 'Win11Debloat'
 
    Invoke-SafeDownload 'https://github.com/Raphire/Win11Debloat/archive/refs/heads/master.zip' $zip 'Win11Debloat'
    Expand-Archive -Path $zip -DestinationPath $extract -Force
 
    $script = Get-ChildItem $extract -Recurse -Filter 'Win11Debloat.ps1' | Select-Object -First 1
    if (-not $script) { throw "Win11Debloat.ps1 introuvable." }
 
    if ($mode -eq '1') {
        $cfg = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'CustomList.txt' } else { $null }
        if ($cfg -and (Test-Path $cfg)) {
            Write-Info "Config : $cfg"
            & $script.FullName -RunDefaults -CustomListPath $cfg
        } else {
            Write-Warn "CustomList.txt absent — valeurs par défaut."
            & $script.FullName -RunDefaults
        }
    } else {
        & $script.FullName
    }
    Write-OK "Win11Debloat terminé."
}
 
# ─── Étape 3 : Office (désinstall + réinstall fr-FR) ──────────────────────────
 
function Get-InstalledOffice {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -and (
                $_.DisplayName -match 'Microsoft (Office|365)' -or
                $_.DisplayName -match 'Microsoft 365 Apps'
            )
        } |
        Select-Object DisplayName, UninstallString, PSChildName
}
 
function Step-Office {
    Write-Step "Microsoft Office — réinstallation propre (fr-FR)"
 
    if (-not (Test-InternetAccess)) { Write-Warn "Pas d'accès Internet."; return }
 
    # --- Détection ---
    $installed = Get-InstalledOffice
    if ($installed) {
        Write-Warn "Versions Office détectées :"
        $installed | ForEach-Object { Write-Host "      - $($_.DisplayName)" -ForegroundColor Yellow }
    } else {
        Write-Info "Aucune version d'Office détectée."
    }
 
    if (-not (Confirm-Action "  Désinstaller Office existant puis installer Microsoft 365 Apps (fr-FR) ?")) {
        Write-Skip "Étape ignorée."; return
    }
 
    # --- Téléchargement ODT (Office Deployment Tool) ---
    # SaRA serait plus complet pour la désinstallation, mais ODT suffit pour C2R.
    # Page officielle : https://www.microsoft.com/en-us/download/details.aspx?id=49117
    $odtUrl  = 'https://download.microsoft.com/download/2/7/A/27AF1BE6-DD20-4CB4-B154-EBAB8A7D4A7E/officedeploymenttool_18526-20144.exe'
    $odtExe  = Join-Path $Script:WorkDir 'odt.exe'
    $odtDir  = Join-Path $Script:WorkDir 'odt'
 
    Invoke-SafeDownload $odtUrl $odtExe 'Office Deployment Tool'
    New-Item -ItemType Directory -Path $odtDir -Force | Out-Null
    Invoke-Process -FilePath $odtExe -ArgumentList @('/quiet', '/extract:' + $odtDir)
 
    $setup = Join-Path $odtDir 'setup.exe'
    if (-not (Test-Path $setup)) { throw "setup.exe ODT introuvable après extraction." }
 
    # --- Désinstallation via ODT ---
    $uninstallXml = Join-Path $odtDir 'uninstall.xml'
    @'
<Configuration>
  <Remove All="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
'@ | Set-Content -Path $uninstallXml -Encoding UTF8
 
    Write-Info "Désinstallation des versions Click-to-Run…"
    try {
        Invoke-Process -FilePath $setup -ArgumentList @('/configure', "`"$uninstallXml`"") -SuccessCodes @(0, 17002)
        Write-OK "Désinstallation terminée."
    } catch {
        Write-Warn "Désinstallation partielle : $_"
    }
 
    # --- Installation fr-FR ---
    $installXml = Join-Path $odtDir 'install.xml'
    $arch64 = if ([Environment]::Is64BitOperatingSystem) { '64' } else { '32' }
    @"
<Configuration>
  <Add OfficeClientEdition="$arch64" Channel="Current">
    <Product ID="O365ProPlusRetail">
      <Language ID="fr-fr" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
      <ExcludeApp ID="Bing" />
    </Product>
  </Add>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="1" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
"@ | Set-Content -Path $installXml -Encoding UTF8
 
    Write-Info "Installation Microsoft 365 Apps fr-FR (peut prendre 10-20 min)…"
    Invoke-Process -FilePath $setup -ArgumentList @('/configure', "`"$installXml`"")
    Write-OK "Microsoft 365 Apps (fr-FR) installé."
}
 
# ─── Étape 4 : Antivirus ──────────────────────────────────────────────────────
 
function Step-Antivirus {
    Write-Step "Vérification des antivirus"
 
    try {
        $av = Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop
        if ($av) {
            Write-Info "Produits enregistrés (SecurityCenter2) :"
            $av | ForEach-Object { Write-Host "      - $($_.displayName)" -ForegroundColor Yellow }
        } else {
            Write-Warn "Aucun antivirus enregistré."
        }
    } catch { Write-Warn "SecurityCenter2 inaccessible : $_" }
 
    $svc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Info "Windows Defender actif."
    } else {
        Write-Warn "Windows Defender inactif/absent."
    }
}
 
# ─── Étape 5 : Chrome ─────────────────────────────────────────────────────────
 
function Test-ChromeInstalled {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    )
    return [bool]($paths | Where-Object { Test-Path $_ } | Select-Object -First 1)
}
 
function Step-Chrome {
    Write-Step "Google Chrome"
 
    if (Test-ChromeInstalled)              { Write-Skip "Chrome déjà installé."; return }
    if (-not (Confirm-Action "  Installer Google Chrome ?")) { Write-Skip "Étape ignorée."; return }
    if (-not (Test-InternetAccess))        { Write-Warn "Pas d'accès Internet."; return }
 
    # MSI offline plus fiable que le stub installer
    $arch = if ([Environment]::Is64BitOperatingSystem) { '64' } else { '' }
    $url  = "https://dl.google.com/tag/s/dl/chrome/install/googlechromestandaloneenterprise$arch.msi"
    $msi  = Join-Path $Script:WorkDir 'chrome.msi'
 
    Invoke-SafeDownload $url $msi 'Chrome MSI'
    Invoke-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$msi`"", '/quiet', '/norestart') -SuccessCodes @(0, 3010)
    Write-OK "Google Chrome installé."
}
 
# ─── Main ─────────────────────────────────────────────────────────────────────
 
try {
    Write-Log 'INIT' "Log : $Script:LogFile" Cyan
 
    Invoke-Step 'PowerShell 7' { Step-PowerShell7 }
    Invoke-Step 'Win11Debloat' { Step-Debloat }
    Invoke-Step 'Office'       { Step-Office }
    Invoke-Step 'Antivirus'    { Step-Antivirus }
    Invoke-Step 'Chrome'       { Step-Chrome }
 
    Write-Host ""
    Write-Log 'DONE' "Script terminé. Log complet : $Script:LogFile" Cyan
} finally {
    Remove-Item $Script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
