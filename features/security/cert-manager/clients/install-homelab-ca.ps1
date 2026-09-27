<#
.SYNOPSIS
  Installe (ou retire) la CA du homelab dans le magasin "Autorités de
  certification racines de confiance" de l'ordinateur local (Windows).

.DESCRIPTION
  1. Récupère le certificat public (URL ou fichier local).
  2. Vérifie son empreinte SHA-256 contre la valeur ÉPINGLÉE ci-dessous
     (jamais contre une valeur téléchargée au même endroit que le
     certificat : ça ne prouverait rien).
  3. L'installe s'il n'est pas déjà présent (relançable sans effet de bord).

  À lancer dans PowerShell ADMINISTRATEUR. Voir
  features/security/cert-manager/README.md.

.EXAMPLE
  .\install-homelab-ca.ps1
  .\install-homelab-ca.ps1 -Source .\homelab-root-ca.crt
  .\install-homelab-ca.ps1 -Check      # vérifie seulement, n'installe rien
  .\install-homelab-ca.ps1 -Uninstall
#>
[CmdletBinding()]
param(
  [string]$Source = "https://raw.githubusercontent.com/cybermimic/iac/main/docs/homelab-root-ca.crt",
  [switch]$Check,
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

# Empreinte SHA-256 de "Homelab Root CA" (docs/homelab-root-ca.crt).
# À mettre à jour ici, dans install-homelab-ca.sh et dans le README si la
# CA est un jour régénérée.
$ExpectedSha256 = "89C0C52EA000AB60C4DF404F495938FE8D3F04BB92E466D22706103D0B7AF67C"
$CertSubject = "CN=Homelab Root CA"

function Get-Sha256Fingerprint([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha.ComputeHash($Cert.RawData))) -replace "-", ""
  } finally {
    $sha.Dispose()
  }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Check -and -not $isAdmin) {
  throw "Lancer PowerShell en administrateur (magasin de l'ordinateur local)."
}

if ($Uninstall) {
  $installed = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -eq $CertSubject }
  if (-not $installed) { Write-Host "Aucune CA '$CertSubject' installée : rien à faire."; return }
  $installed | ForEach-Object {
    Write-Host "Retrait de $($_.Subject) (empreinte SHA-1 $($_.Thumbprint))"
    Remove-Item -Path "Cert:\LocalMachine\Root\$($_.Thumbprint)"
  }
  return
}

# 1. Récupération
if ($Source -match "^https?://") {
  $file = Join-Path $env:TEMP "homelab-root-ca.crt"
  Invoke-WebRequest -Uri $Source -OutFile $file -UseBasicParsing
} else {
  $file = (Resolve-Path $Source).Path
}
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($file)

# 2. Vérification
$actual = Get-Sha256Fingerprint $cert
if ($actual -ne $ExpectedSha256) {
  throw "EMPREINTE INCORRECTE — certificat NON installé.`n  attendue : $ExpectedSha256`n  obtenue  : $actual"
}
Write-Host "Empreinte SHA-256 conforme : $actual ($($cert.Subject), valide jusqu'au $($cert.NotAfter.ToString('yyyy-MM-dd')))"
if ($Check) { return }

# 3. Installation (idempotente)
if (Test-Path "Cert:\LocalMachine\Root\$($cert.Thumbprint)") {
  Write-Host "Déjà installée : rien à faire."
  return
}
Import-Certificate -FilePath $file -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Write-Host "CA installée. Redémarrer le navigateur pour qu'il la prenne en compte."
