<#
    Migra la configuracion de Database Mail de EROS a PEON.
    Requiere Migrar-DatabaseMail.ps1 en la misma carpeta.

    .\Migrar-DatabaseMail-Eros-Peon.ps1 -SoloRevisar
    .\Migrar-DatabaseMail-Eros-Peon.ps1 -CorreoPrueba dba@comfamiliarhuila.com
    .\Migrar-DatabaseMail-Eros-Peon.ps1 -Reemplazar
#>
param([switch]$SoloRevisar, [switch]$Reemplazar, [string]$CorreoPrueba, [string]$PerfilAgente)

$principal = Join-Path $PSScriptRoot 'Migrar-DatabaseMail.ps1'
if (-not (Test-Path $principal)) {
    Write-Host "ERROR: no se encuentra $principal (debe estar en la misma carpeta)." -ForegroundColor Red
    exit 1
}

& $principal -Origen 'eros' -Destino 'peon' `
             -Carpeta 'C:\temp\sync_dbmail\eros_a_peon' `
             -SoloRevisar:$SoloRevisar -Reemplazar:$Reemplazar -CorreoPrueba $CorreoPrueba -PerfilAgente $PerfilAgente
exit $LASTEXITCODE
