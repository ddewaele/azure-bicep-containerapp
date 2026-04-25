# Entra Connect Sync — manual install guide

Entra Connect (formerly Azure AD Connect) is a Windows MSI installer that runs
interactively. It cannot practically be deployed via Bicep — this guide covers
the manual steps to run on `dc-vm` after the rest of the project is up.

> **⚠ Warning: this modifies your real Entra tenant.**
> Users from the `Demo` OU will be synced into the Entra tenant you sign in with.
> Use a **test/sandbox tenant** (e.g. a free `.onmicrosoft.com` tenant) for this
> demo — not your production tenant. Clean up synced users when done.

## Prerequisites

- `dc-vm` is a domain controller for `corp.local` (scripts/setup-adds.ps1).
- Test users exist in `OU=Demo,DC=corp,DC=local` (scripts/seed-users.ps1).
- You can sign in to an Entra tenant as **Global Administrator**.
- The tenant has at least one verified custom domain (or you're OK with
  users synced using the `...onmicrosoft.com` suffix — see below).

## 1. Download Entra Connect

On `dc-vm`:

```powershell
$url       = 'https://download.microsoft.com/download/B/0/0/B00291D0-5A83-4DE7-86F5-980BC00DE05A/AzureADConnect.msi'
$installer = "$env:TEMP\AzureADConnect.msi"
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
Start-Process $installer
```

(Or grab the latest from <https://www.microsoft.com/download/details.aspx?id=47594>.)

## 2. Run the installer

1. Accept the license.
2. Pick **Express Settings** if your `corp.local` UPN matches a verified
   Entra domain. Otherwise pick **Customize** and:
   - **User sign-in:** Password Hash Synchronization (simplest).
   - **Connect to Azure AD:** sign in with a Global Admin account.
   - **Connect directory:** `corp.local`, provide enterprise admin creds
     (e.g. `CORP\azureadmin`).
   - **Domain/OU filtering:** restrict to `OU=Demo,DC=corp,DC=local` to avoid
     syncing the whole directory.
   - **User identifying attribute:** `userPrincipalName` (default).
3. Confirm and install. First sync runs automatically and takes ~5 minutes.

## 3. Verify in Entra

```bash
# From your dev machine (signed in to the same tenant)
az ad user list --query "[?contains(userPrincipalName, '@corp.local')].{upn:userPrincipalName, name:displayName}" -o table
```

You should see `alice@corp.local` and `bob@corp.local` (or `alice@<tenant>.onmicrosoft.com`
if you didn't configure UPN suffix mapping).

## 4. About the UPN / verified domain

If `corp.local` is not a verified domain in your Entra tenant, Entra Connect
will rewrite the UPN suffix to `<tenant>.onmicrosoft.com` for each synced user.
That's fine for a demo — users still sync, just with a different UPN in Entra.

To fix this properly you'd:
- Own a real public domain (e.g. `mycorp.com`).
- Verify it in your Entra tenant.
- Add it as an alternative UPN suffix in AD DS.
- Update users' UPNs to `@mycorp.com`.

## 5. Clean up

Either:

- Uninstall Entra Connect from **Add/Remove Programs**, then manually delete
  the synced users from Entra, **or**
- Tear down the whole resource group (`az group delete --name $RG --yes`) —
  this removes the DC but **does not** remove already-synced users from Entra.
  You still need to delete them manually.

```bash
# Delete the two demo users from Entra
az ad user delete --id 'alice@<tenant>.onmicrosoft.com'
az ad user delete --id 'bob@<tenant>.onmicrosoft.com'
```
