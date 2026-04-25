# =============================================================================
# Promote this Windows Server to a domain controller.
# Creates a new AD forest: corp.local (NetBIOS: CORP).
#
# Run this from an elevated PowerShell prompt on dc-vm after RDP'ing in.
# The VM will reboot automatically when promotion completes (~10 minutes).
# =============================================================================

$DomainName  = 'corp.local'
$NetBiosName = 'CORP'

Write-Host "Installing AD DS role..." -ForegroundColor Cyan
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

Write-Host "`nEnter the Directory Services Restore Mode (DSRM) password:" -ForegroundColor Yellow
$SafeModePassword = Read-Host -AsSecureString

Write-Host "`nPromoting to domain controller for $DomainName ..." -ForegroundColor Cyan
Install-ADDSForest `
  -DomainName                  $DomainName `
  -DomainNetbiosName           $NetBiosName `
  -DomainMode                  'WinThreshold' `
  -ForestMode                  'WinThreshold' `
  -InstallDns                  `
  -SafeModeAdministratorPassword $SafeModePassword `
  -NoRebootOnCompletion:       $false `
  -Force
