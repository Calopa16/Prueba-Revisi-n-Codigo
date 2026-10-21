<#
    Migra los certificados de master (ej. CertiBDProduction) de TANATOS a HERMES.
    Requiere Migrar-Certificados.ps1 en la misma carpeta.

    .\Migrar-Certificados-Tanatos-Hermes.ps1 -SoloRevisar
    .\Migrar-Certificados-Tanatos-Hermes.ps1
    .\Migrar-Certificados-Tanatos-Hermes.ps1 -Respaldo      # ademas guarda .cer/.pvk en la carpeta
#>
param([switch]$SoloRevisar, [switch]$Reemplazar, [switch]$Respaldo, [string[]]$Certificados = @('*'))

$principal = Join-Path $PSScriptRoot 'Migrar-Certificados.ps1'
if (-not (Test-Path $principal)) {
    Write-Host "ERROR: no se encuentra $principal (debe estar en la misma carpeta)." -ForegroundColor Red
    exit 1
}

$extra = @{}
if ($Respaldo) { $extra['PasswordRespaldo'] = Read-Host -AsSecureString 'Contrasena para cifrar el respaldo .pvk (guardela en lugar seguro)' }

& $principal -Origen 'tanatos' -Destino 'hermes' -Certificados $Certificados `
             -Carpeta 'C:\temp\sync_certificados\tanatos_a_hermes' `
             -SoloRevisar:$SoloRevisar -Reemplazar:$Reemplazar @extra
exit $LASTEXITCODE
