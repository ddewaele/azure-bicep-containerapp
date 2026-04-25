# =============================================================================
# Mount an Azure Files share as a local drive letter on Windows.
# Uses storage account key auth (simplest — works without AD integration).
#
# Usage:
#   .\mount-azure-files.ps1 `
#     -StorageAccount "hybsyncxxxxxxxx" `
#     -ShareName      "hybrid-share" `
#     -StorageKey     "<primary-key-from-az-storage-account-keys-list>" `
#     -DriveLetter    "Z"
# =============================================================================
param(
  [Parameter(Mandatory=$true)][string] $StorageAccount,
  [Parameter(Mandatory=$true)][string] $ShareName,
  [Parameter(Mandatory=$true)][string] $StorageKey,
  [string] $DriveLetter = 'Z'
)

$fqdn = "$StorageAccount.file.core.windows.net"
$unc  = "\\$fqdn\$ShareName"

Write-Host "Saving credentials to Windows Credential Manager for $fqdn ..." -ForegroundColor Cyan
cmdkey /add:"$fqdn" /user:"localhost\$StorageAccount" /pass:"$StorageKey" | Out-Null

Write-Host "Mounting $unc as ${DriveLetter}: ..." -ForegroundColor Cyan
New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $unc -Persist -Scope Global

Write-Host "`nMounted. Verify with: dir ${DriveLetter}:" -ForegroundColor Green
