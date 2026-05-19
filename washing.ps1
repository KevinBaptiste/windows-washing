<#
.SYNOPSIS
    Préparation automatisée d'un poste Windows.
.DESCRIPTION
    1. Installe PowerShell 7 (dernière version, détection d'architecture)
    2. Lance Win11Debloat de Raphire (mode config ou interactif)
    3. Vérifie la présence d'antivirus de base (SecurityCenter2 + WinDefend)
    4. Installe Google Chrome si absent
.NOTES
    Doit être exécuté en tant qu'administrateur.
    Utilisation : irm <raw_url> -OutFile washing.ps1; .\washing.ps1
#>
#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step { param([int]$n, [string]$Msg) Write-Host "`n[$n/4] $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "  [-]  $Msg" -ForegroundColor DarkGray }
function Write-Fail { param([string]$Msg) Write-Host "  [X]  $Msg" -ForegroundColor Red }
function Write-Warn { param([string]$Msg) Write-Host "  [!]  $Msg" -ForegroundColor Yellow }

function Confirm-Action {
    param([string]$Prompt)
    $reply = Read-Host "$Prompt [O/n]"
    return ($reply -eq '' -or $reply -imatch '^o')
}

function Get-SystemArch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { return 'arm64' }
        'AMD64' { return 'x64'   }
        default  { return 'x86'   }
    }
}

function Test-NetworkAccess {
    try {
        $null = [System.Net.Dns]::GetHostEntry('github.com')
        return $true
    } catch {
        return $false
    }
}

function Invoke-Download {
    param([string]$Url, [string]$Destination, [string]$Label)
    Write-Host "  Téléchargement de $Label…"
    Invoke-WebRequest $Url -OutFile $Destination -UseBasicParsing
}

# ─── 1. PowerShell 7 ──────────────────────────────────────────────────────────

Write-Step 1 "PowerShell 7 — dernière version"

if (-not (Test-NetworkAccess)) {
    Write-Warn "Pas d'accès réseau — étape ignorée."
} else {
    try {
        $rel       = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
        $latestVer = [version]$rel.tag_name.TrimStart('v')
        $arch      = Get-SystemArch

        $currentVer = [version]"$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"
        $upToDate   = $PSVersionTable.PSVersion.Major -ge 7 -and $currentVer -ge $latestVer

        if ($upToDate) {
            Write-Skip "PowerShell $currentVer est déjà à jour (dernière : $latestVer)."
        } elseif (Confirm-Action "  Installer PowerShell $latestVer ($arch) ?") {
            $asset = $rel.assets | Where-Object { $_.name -like "*win-$arch.msi" } | Select-Object -First 1
            if (-not $asset) { throw "Aucun installeur MSI trouvé pour l'architecture $arch." }

            $msi = Join-Path $env:TEMP $asset.name
            try {
                Invoke-Download $asset.browser_download_url $msi $asset.name
                Write-Host "  Installation…"
                Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait
                Write-OK "PowerShell $latestVer installé — relancez le terminal."
            } finally {
                Remove-Item $msi -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Skip "Étape ignorée."
        }
    } catch {
        Write-Fail "Étape 1 : $_"
    }
}

# ─── 2. Raphire / Win11Debloat ────────────────────────────────────────────────

Write-Step 2 "Raphire / Win11Debloat"

Write-Host "  Choisissez un mode :"
Write-Host "   [1] Suppression automatique via fichier de configuration"
Write-Host "   [2] Panneau de sélection interactif"
Write-Host "   [0] Ignorer"
$debloatMode = Read-Host "  Votre choix"

if ($debloatMode -notin @('1', '2')) {
    Write-Skip "Étape ignorée."
} elseif (-not (Test-NetworkAccess)) {
    Write-Warn "Pas d'accès réseau — étape ignorée."
} else {
    $zipPath    = Join-Path $env:TEMP 'Win11Debloat.zip'
    $extractDir = Join-Path $env:TEMP 'Win11Debloat'
    try {
        Invoke-Download 'https://github.com/Raphire/Win11Debloat/archive/refs/heads/master.zip' $zipPath 'Win11Debloat'
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Expand-Archive $zipPath $extractDir

        $debloatScript = Get-ChildItem $extractDir -Recurse -Filter 'Win11Debloat.ps1' | Select-Object -First 1
        if (-not $debloatScript) { throw "Win11Debloat.ps1 introuvable dans l'archive." }

        if ($debloatMode -eq '1') {
            $configFile = Join-Path $PSScriptRoot 'CustomList.txt'
            if (Test-Path $configFile) {
                Write-Host "  Fichier de config : $configFile"
                & $debloatScript.FullName -RunDefaults -CustomListPath $configFile
            } else {
                Write-Warn "CustomList.txt absent de $PSScriptRoot — valeurs par défaut utilisées."
                & $debloatScript.FullName -RunDefaults
            }
        } else {
            & $debloatScript.FullName
        }
        Write-OK "Win11Debloat terminé."
    } catch {
        Write-Fail "Étape 2 : $_"
    } finally {
        Remove-Item $zipPath    -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── 3. Antivirus de base ─────────────────────────────────────────────────────

Write-Step 3 "Vérification des antivirus de base"

$knownAV     = @('Windows Defender', 'Microsoft Defender', 'McAfee', 'Norton', 'Avast', 'AVG', 'Kaspersky', 'Bitdefender')
$installedAV = @()

try {
    $installedAV = @(
        Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty displayName
    )
} catch {}

$detectedAV = $installedAV | Where-Object {
    $av = $_
    @($knownAV | Where-Object { $av -like "*$_*" }).Count -gt 0
}

if ($detectedAV) {
    Write-Warn "Antivirus détectés :"
    $detectedAV | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
} else {
    Write-OK "Aucun antivirus connu détecté via SecurityCenter2."
}

$defenderService = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
if ($defenderService -and $defenderService.Status -eq 'Running') {
    Write-Warn "Windows Defender (WinDefend) est actif."
} else {
    Write-OK "Service Windows Defender inactif ou absent."
}

# ─── 4. Google Chrome ─────────────────────────────────────────────────────────

Write-Step 4 "Google Chrome — dernière version"

$chromeRegPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
)
$chromeFound = $chromeRegPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($chromeFound) {
    Write-Skip "Google Chrome est déjà installé."
} elseif (-not (Confirm-Action "  Télécharger et installer Google Chrome ?")) {
    Write-Skip "Étape ignorée."
} elseif (-not (Test-NetworkAccess)) {
    Write-Warn "Pas d'accès réseau — étape ignorée."
} else {
    $installer = Join-Path $env:TEMP 'chrome_installer.exe'
    try {
        Invoke-Download 'https://dl.google.com/chrome/install/latest/chrome_installer.exe' $installer 'Chrome'
        Write-Host "  Installation…"
        Start-Process $installer -ArgumentList '/silent /install' -Wait
        Write-OK "Google Chrome installé."
    } catch {
        Write-Fail "Étape 4 : $_"
    } finally {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`nScript terminé." -ForegroundColor Cyan
