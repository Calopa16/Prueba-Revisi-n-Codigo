<#
    Migra la configuracion de Database Mail de TANATOS a HERMES.
    Requiere Migrar-DatabaseMail.ps1 en la misma carpeta.

    .\Migrar-DatabaseMail-Tanatos-Hermes.ps1 -SoloRevisar
    .\Migrar-DatabaseMail-Tanatos-Hermes.ps1 -CorreoPrueba dba@comfamiliarhuila.com
    .\Migrar-DatabaseMail-Tanatos-Hermes.ps1 -Reemplazar
#>
param([switch]$SoloRevisar, [switch]$Reemplazar, [string]$CorreoPrueba, [string]$PerfilAgente)

$principal = Join-Path $PSScriptRoot 'Migrar-DatabaseMail.ps1'
if (-not (Test-Path $principal)) {
    Write-Host "ERROR: no se encuentra $principal (debe estar en la misma carpeta)." -ForegroundColor Red
    exit 1
}

& $principal -Origen 'tanatos' -Destino 'hermes' `
             -Carpeta 'C:\temp\sync_dbmail\tanatos_a_hermes' `
             -SoloRevisar:$SoloRevisar -Reemplazar:$Reemplazar -CorreoPrueba $CorreoPrueba -PerfilAgente $PerfilAgente
exit $LASTEXITCODE
