# =============================================================================
# Seed a test OU and users in the corp.local domain.
# Run this AFTER the DC reboots from setup-adds.ps1 and you've logged back in
# (now as CORP\azureadmin).
#
# Creates:
#   OU=Demo
#     alice@corp.local
#     bob@corp.local
#
# These are the users you'll sync to Entra ID via Entra Connect later.
# =============================================================================

$DomainDN = (Get-ADDomain).DistinguishedName
$OUPath   = "OU=Demo,$DomainDN"

Write-Host "Creating OU=Demo ..." -ForegroundColor Cyan
if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Demo'" -ErrorAction SilentlyContinue)) {
  New-ADOrganizationalUnit -Name 'Demo' -Path $DomainDN -ProtectedFromAccidentalDeletion $false
}

Write-Host "`nEnter password for demo users (alice, bob):" -ForegroundColor Yellow
$Password = Read-Host -AsSecureString

$users = @(
  @{ Given='Alice'; Sur='Example'; Sam='alice' },
  @{ Given='Bob';   Sur='Example'; Sam='bob'   }
)

foreach ($u in $users) {
  Write-Host "Creating $($u.Given) $($u.Sur) ..." -ForegroundColor Cyan
  New-ADUser `
    -Name              "$($u.Given) $($u.Sur)" `
    -GivenName         $u.Given `
    -Surname           $u.Sur `
    -SamAccountName    $u.Sam `
    -UserPrincipalName "$($u.Sam)@corp.local" `
    -AccountPassword   $Password `
    -Enabled           $true `
    -Path              $OUPath
}

Write-Host "`nDone. View users with: Get-ADUser -Filter * -SearchBase '$OUPath'" -ForegroundColor Green
