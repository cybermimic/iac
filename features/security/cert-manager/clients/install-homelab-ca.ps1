<#
.SYNOPSIS
  Installe (ou retire) la CA du homelab dans le magasin "Autorites de
  certification racines de confiance" de l'ordinateur local (Windows).

.DESCRIPTION
  1. Recupere le certificat public (URL ou fichier local).
  2. Verifie son empreinte SHA-256 contre la valeur EPINGLEE ci-dessous
     (jamais contre une valeur telechargee au meme endroit que le
     certificat : ca ne prouverait rien).
  3. L'installe s'il n'est pas deja present (relancable sans effet de bord).

  A lancer dans PowerShell ADMINISTRATEUR. Voir
  features/security/cert-manager/README.md.

.EXAMPLE
  .\install-homelab-ca.ps1
  .\install-homelab-ca.ps1 -Source .\homelab-root-ca.crt
  .\install-homelab-ca.ps1 -Check      # verifie seulement, n'installe rien
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
# A mettre a jour ici, dans install-homelab-ca.sh et dans le README si la
# CA est un jour regeneree.
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

# -Check ne modifie rien : pas besoin des droits administrateur.
if (-not $Check) {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    throw "Lancer PowerShell en administrateur (magasin de l'ordinateur local)."
  }
}

if ($Uninstall) {
  $installed = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -eq $CertSubject }
  if (-not $installed) { Write-Host "Aucune CA '$CertSubject' installee : rien a faire."; return }
  $installed | ForEach-Object {
    Write-Host "Retrait de $($_.Subject) (empreinte SHA-1 $($_.Thumbprint))"
    Remove-Item -Path "Cert:\LocalMachine\Root\$($_.Thumbprint)"
  }
  return
}

# 1. Recuperation
if ($Source -match "^https?://") {
  $file = Join-Path $env:TEMP "homelab-root-ca.crt"
  Invoke-WebRequest -Uri $Source -OutFile $file -UseBasicParsing
} else {
  $file = (Resolve-Path $Source).Path
}
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($file)

# 2. Verification
$actual = Get-Sha256Fingerprint $cert
if ($actual -ne $ExpectedSha256) {
  throw "EMPREINTE INCORRECTE - certificat NON installe.`n  attendue : $ExpectedSha256`n  obtenue  : $actual"
}
Write-Host "Empreinte SHA-256 conforme : $actual ($($cert.Subject), valide jusqu'au $($cert.NotAfter.ToString('yyyy-MM-dd')))"
if ($Check) { return }

# 3. Installation (idempotente)
if (Test-Path "Cert:\LocalMachine\Root\$($cert.Thumbprint)") {
  Write-Host "Deja installee : rien a faire."
  return
}
Import-Certificate -FilePath $file -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Write-Host "CA installee. Redemarrer le navigateur pour qu'il la prenne en compte."
