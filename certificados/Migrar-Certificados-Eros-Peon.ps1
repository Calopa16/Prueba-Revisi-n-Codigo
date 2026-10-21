<#
    Migra los certificados de master (ej. CertiBDProduction) de EROS a PEON.
    Requiere Migrar-Certificados.ps1 en la misma carpeta.

    .\Migrar-Certificados-Eros-Peon.ps1 -SoloRevisar
    .\Migrar-Certificados-Eros-Peon.ps1
    .\Migrar-Certificados-Eros-Peon.ps1 -Respaldo      # ademas guarda .cer/.pvk en la carpeta
#>
param([switch]$SoloRevisar, [switch]$Reemplazar, [switch]$Respaldo, [string[]]$Certificados = @('*'))

$principal = Join-Path $PSScriptRoot 'Migrar-Certificados.ps1'
if (-not (Test-Path $principal)) {
    Write-Host "ERROR: no se encuentra $principal (debe estar en la misma carpeta)." -ForegroundColor Red
    exit 1
}

$extra = @{}
if ($Respaldo) { $extra['PasswordRespaldo'] = Read-Host -AsSecureString 'Contrasena para cifrar el respaldo .pvk (guardela en lugar seguro)' }

& $principal -Origen 'eros' -Destino 'peon' -Certificados $Certificados `
             -Carpeta 'C:\temp\sync_certificados\eros_a_peon' `
             -SoloRevisar:$SoloRevisar -Reemplazar:$Reemplazar @extra
exit $LASTEXITCODE
