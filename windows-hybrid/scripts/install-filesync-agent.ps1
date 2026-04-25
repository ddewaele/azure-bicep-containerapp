# =============================================================================
# Download and install the Azure File Sync agent for Windows Server 2022.
# Run from an elevated PowerShell prompt on dc-vm.
#
# After install, register the server with the sync service via:
#   - Server Registration UI (auto-launches on first run), OR
#   - PowerShell:
#       Import-Module 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerRegistration.dll'
#       Register-AzStorageSyncServer -ResourceGroupName <rg> -StorageSyncServiceName <svc>
# =============================================================================

$url       = 'https://aka.ms/AzureFileSyncAgent/WindowsServer2022/Latest'
$installer = Join-Path $env:TEMP 'AzureFileSyncAgent.msi'

Write-Host "Downloading Azure File Sync agent ..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing

Write-Host "Installing ..." -ForegroundColor Cyan
$exit = (Start-Process msiexec.exe `
  -ArgumentList @('/i', $installer, '/quiet', '/norestart') `
  -Wait -PassThru).ExitCode

if ($exit -ne 0) {
  throw "Install failed with exit code $exit"
}

Write-Host "`nAgent installed. Server Registration UI will auto-launch — sign in and select your sync service." -ForegroundColor Green
