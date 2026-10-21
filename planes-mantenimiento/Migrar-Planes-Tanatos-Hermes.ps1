<#
    Migra TODOS los planes de mantenimiento de TANATOS a HERMES.
    Requiere Migrar-PlanesMantenimiento.ps1 en la misma carpeta.

    .\Migrar-Planes-Tanatos-Hermes.ps1 -SoloRevisar    # solo revisar
    .\Migrar-Planes-Tanatos-Hermes.ps1                 # migrar (jobs deshabilitados)
    .\Migrar-Planes-Tanatos-Hermes.ps1 -Reemplazar     # sobrescribir los que ya existan
#>
param([switch]$SoloRevisar, [switch]$Reemplazar, [switch]$JobsActivos)

$principal = Join-Path $PSScriptRoot 'Migrar-PlanesMantenimiento.ps1'
if (-not (Test-Path $principal)) {
    Write-Host "ERROR: no se encuentra $principal (debe estar en la misma carpeta)." -ForegroundColor Red
    exit 1
}

& $principal -Origen 'tanatos' -Destino 'hermes' `
             -Carpeta 'C:\temp\sync_planes\tanatos_a_hermes' `
             -SoloRevisar:$SoloRevisar -Reemplazar:$Reemplazar -JobsActivos:$JobsActivos
exit $LASTEXITCODE
