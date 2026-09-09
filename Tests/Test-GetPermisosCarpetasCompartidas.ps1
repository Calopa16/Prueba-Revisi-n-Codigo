<#
=============================================================================
  Test-GetPermisosCarpetasCompartidas.ps1

  Pruebas de las funciones puras de Get-PermisosCarpetasCompartidas.ps1
  (traducción de máscaras de permisos, normalización del nombre de servidor,
  filtros de identidad y armado del informe).

  No tocan la red ni el sistema de archivos: las funciones se extraen del AST
  del script y se evalúan de forma aislada, así que las pruebas corren en
  cualquier equipo, incluso sin acceso a un servidor de archivos.

  Uso
  ---
  pwsh -File .\Tests\Test-GetPermisosCarpetasCompartidas.ps1
  Código de salida 0 = todo correcto; 1 = alguna prueba falló.
=============================================================================
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rutaScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Get-PermisosCarpetasCompartidas.ps1'
if (-not (Test-Path -LiteralPath $rutaScript)) {
    throw "No se encontró el script a probar en '$rutaScript'."
}

$errores = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($rutaScript, [ref]$tokens, [ref]$errores)
if ($errores) {
    $errores | ForEach-Object { Write-Host "ERROR de sintaxis (línea $($_.Extent.StartLineNumber)): $($_.Message)" }
    exit 1
}
Write-Host "Sintaxis del script: OK" -ForegroundColor Green

# Solo se cargan las funciones sin dependencias de red ni de Windows.
$funcionesPuras = 'Resolve-NombreEquipo', 'ConvertTo-PermisoLegible', 'Test-IdentidadFiltrada', 'ConvertTo-FilaPermiso'
$definiciones = $ast.FindAll({ param($nodo) $nodo -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($definicion in $definiciones) {
    if ($funcionesPuras -contains $definicion.Name) { . ([scriptblock]::Create($definicion.Extent.Text)) }
}

# Variables que las funciones toman del ámbito del script.
$script:CuentasSistema = @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', 'CREATOR OWNER')
$IncluirCuentasSistema = $false
$SoloUsuario = $null

$script:fallos = 0
function Assert-Igual {
    param($Esperado, $Real, [string]$Caso)

    if ("$Esperado" -eq "$Real") {
        Write-Host "  OK    $Caso"
    }
    else {
        $script:fallos++
        Write-Host "  FALLA $Caso -> esperado '$Esperado', obtenido '$Real'" -ForegroundColor Red
    }
}

Write-Host "`nResolve-NombreEquipo"
Assert-Igual '10.10.1.65' (Resolve-NombreEquipo '\\10.10.1.65')      'ruta UNC con IP'
Assert-Igual '10.10.1.65' (Resolve-NombreEquipo '10.10.1.65')        'IP sin barras'
Assert-Igual 'SRVFILES'   (Resolve-NombreEquipo '\\SRVFILES\Datos')  'UNC con recurso incluido'
Assert-Igual 'SRVFILES'   (Resolve-NombreEquipo '  \\SRVFILES\  ')   'espacios y barra final'
try {
    Resolve-NombreEquipo '   ' | Out-Null
    $script:fallos++
    Write-Host "  FALLA valor vacio deberia lanzar excepcion" -ForegroundColor Red
}
catch { Write-Host "  OK    valor vacio lanza excepcion" }

Write-Host "`nConvertTo-PermisoLegible"
Assert-Igual 'Control total'       (ConvertTo-PermisoLegible ([System.Security.AccessControl.FileSystemRights]::FullControl))    'FullControl'
Assert-Igual 'Modificar'           (ConvertTo-PermisoLegible ([System.Security.AccessControl.FileSystemRights]::Modify))         'Modify'
Assert-Igual 'Lectura y ejecución' (ConvertTo-PermisoLegible ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)) 'ReadAndExecute'
Assert-Igual 'Lectura'             (ConvertTo-PermisoLegible ([System.Security.AccessControl.FileSystemRights]::Read))           'Read'
Assert-Igual 'Escritura'           (ConvertTo-PermisoLegible ([System.Security.AccessControl.FileSystemRights]::Write))          'Write'
Assert-Igual 'Control total'       (ConvertTo-PermisoLegible 268435456)                                                          'GENERIC_ALL'
Assert-Igual 'Escritura'           (ConvertTo-PermisoLegible 1073741824)                                                         'GENERIC_WRITE'
Assert-Igual 'Lectura'             (ConvertTo-PermisoLegible ([int]'-2147483648'))                                               'GENERIC_READ (bit de signo)'
$especial = ConvertTo-PermisoLegible ([System.Security.AccessControl.FileSystemRights]::ReadAttributes)
if ($especial -like 'Especial*') { Write-Host "  OK    derecho suelto se marca como Especial" }
else { $script:fallos++; Write-Host "  FALLA derecho suelto -> '$especial'" -ForegroundColor Red }

Write-Host "`nTest-IdentidadFiltrada"
Assert-Igual $true  (Test-IdentidadFiltrada 'NT AUTHORITY\SYSTEM') 'cuenta de sistema se descarta'
Assert-Igual $false (Test-IdentidadFiltrada 'CONTOSO\jperez')      'usuario normal se conserva'

$SoloUsuario = @('*jperez*')
Assert-Igual $false (Test-IdentidadFiltrada 'CONTOSO\jperez') '-SoloUsuario deja pasar la coincidencia'
Assert-Igual $true  (Test-IdentidadFiltrada 'CONTOSO\mlopez') '-SoloUsuario descarta al resto'
$SoloUsuario = $null

$IncluirCuentasSistema = $true
Assert-Igual $false (Test-IdentidadFiltrada 'NT AUTHORITY\SYSTEM') '-IncluirCuentasSistema conserva SYSTEM'
$IncluirCuentasSistema = $false

Write-Host "`nConvertTo-FilaPermiso"
$fila = ConvertTo-FilaPermiso -Equipo '10.10.1.65' `
    -RecursoInfo ([pscustomobject]@{ Nombre = 'Contabilidad'; RutaLocal = 'D:\Datos\Conta' }) `
    -Ruta '\\10.10.1.65\Contabilidad\2026' -Origen 'NTFS' -Identidad 'CONTOSO\jperez' `
    -EsGrupo $false -ViaGrupo 'CONTOSO\GG_Conta' -Permiso 'Modificar' -TipoAcceso 'Allow' `
    -Heredado $true -Propietario 'CONTOSO\admin'
Assert-Igual 'Contabilidad'     $fila.Recurso   'nombre del recurso'
Assert-Igual 'D:\Datos\Conta'   $fila.RutaLocal 'ruta local del recurso'
Assert-Igual 'CONTOSO\GG_Conta' $fila.ViaGrupo  'grupo por el que llega el permiso'
Assert-Igual 12 (@($fila.PSObject.Properties.Name)).Count 'columnas del informe'
try {
    ConvertTo-FilaPermiso -Equipo 's' -RecursoInfo ([pscustomobject]@{ Nombre = 'R'; RutaLocal = $null }) `
        -Ruta '\\s\R' -Origen 'Inventado' -Identidad 'u' -EsGrupo $false -ViaGrupo $null `
        -Permiso 'Lectura' -TipoAcceso 'Allow' -Heredado $false -Propietario $null | Out-Null
    $script:fallos++
    Write-Host "  FALLA un origen invalido deberia rechazarse" -ForegroundColor Red
}
catch { Write-Host "  OK    origen invalido rechazado por ValidateSet" }

Write-Host "`nAgregación por usuario"
$plantilla = [pscustomobject]@{ Nombre = 'R'; RutaLocal = $null }
$detalle = @(
    ConvertTo-FilaPermiso -Equipo 's' -RecursoInfo $plantilla -Ruta '\\s\R'   -Origen 'NTFS' -Identidad 'CONTOSO\jperez' -EsGrupo $false -ViaGrupo $null -Permiso 'Modificar' -TipoAcceso 'Allow' -Heredado $false -Propietario $null
    ConvertTo-FilaPermiso -Equipo 's' -RecursoInfo $plantilla -Ruta '\\s\R\A' -Origen 'NTFS' -Identidad 'CONTOSO\jperez' -EsGrupo $false -ViaGrupo $null -Permiso 'Lectura'   -TipoAcceso 'Allow' -Heredado $false -Propietario $null
    ConvertTo-FilaPermiso -Equipo 's' -RecursoInfo $plantilla -Ruta '\\s\R\A' -Origen 'NTFS' -Identidad 'CONTOSO\jperez' -EsGrupo $false -ViaGrupo $null -Permiso 'Lectura'   -TipoAcceso 'Allow' -Heredado $false -Propietario $null
    ConvertTo-FilaPermiso -Equipo 's' -RecursoInfo $plantilla -Ruta '\\s\R\A' -Origen 'NTFS' -Identidad 'CONTOSO\mlopez' -EsGrupo $false -ViaGrupo $null -Permiso 'Lectura'   -TipoAcceso 'Allow' -Heredado $false -Propietario $null
)
$porUsuario = @($detalle | Group-Object Identidad | ForEach-Object {
    [pscustomobject]@{
        Identidad = $_.Name
        Carpetas  = @($_.Group.Ruta | Sort-Object -Unique).Count
        Permisos  = (@($_.Group.Permiso | Sort-Object -Unique) -join ', ')
        Rutas     = (@($_.Group.Ruta | Sort-Object -Unique) -join '; ')
    }
} | Sort-Object Identidad)
Assert-Igual 2 $porUsuario.Count                    'una fila por identidad'
Assert-Igual 2 $porUsuario[0].Carpetas              'carpetas distintas de jperez'
Assert-Igual 'Lectura, Modificar' $porUsuario[0].Permisos 'permisos consolidados de jperez'
Assert-Igual 1 $porUsuario[1].Carpetas              'carpetas distintas de mlopez'

if ($script:fallos -gt 0) {
    Write-Host "`n$($script:fallos) prueba(s) fallida(s)" -ForegroundColor Red
    exit 1
}
Write-Host "`nTodas las pruebas pasaron" -ForegroundColor Green
exit 0
