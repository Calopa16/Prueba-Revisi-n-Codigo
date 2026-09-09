<#
=============================================================================
  Get-PermisosCarpetasCompartidas.ps1

  Audita un servidor de archivos Windows (por nombre o por IP, p. ej.
  \\10.10.1.65) y responde a dos preguntas:

    1) Qué carpetas se publican y qué usuarios o grupos tienen permiso en cada
       una (permisos de recurso compartido SMB + permisos NTFS).
    2) A la inversa: a qué carpetas llega cada usuario o grupo.

  Requisitos
  ----------
  - Windows PowerShell 5.1 o PowerShell 7 sobre Windows.
  - Cuenta con permiso de lectura sobre los recursos y sus ACL. Para leer los
    permisos del recurso compartido y los recursos administrativos hace falta
    ser administrador local del servidor auditado.
  - Puertos SMB (445) y, para la enumeración por CIM/WMI, WinRM (5985) o
    DCOM/RPC (135 + rango dinámico) abiertos hacia el servidor.

  Parámetros
  ----------
  -Servidor                        Nombre o IP del servidor. Admite '\\10.10.1.65'.
  -Recurso                         Uno o varios recursos compartidos a auditar.
                                   Admite comodines ('Conta*'). Por defecto, todos.
  -Profundidad                     Niveles de subcarpetas por debajo de la raíz del
                                   recurso. 0 = solo la raíz de cada recurso.
  -SoloUsuario                     Filtra el informe a una o varias identidades
                                   ('DOMINIO\jperez', '*jperez*').
  -IncluirRecursosAdministrativos  Incluye C$, ADMIN$, IPC$, print$...
  -IncluirHeredados                Incluye las ACE heredadas del padre. Por defecto
                                   solo se listan los permisos explícitos, que son
                                   los que definen la delegación real.
  -IncluirCuentasSistema           Incluye SYSTEM, Administradores, CREATOR OWNER...
  -ExpandirGrupos                  Resuelve los grupos a sus usuarios miembros
                                   (recursivo) para obtener la lista real de personas.
  -CarpetaSalida                   Directorio donde escribir los CSV del informe.
  -Credencial                      Credenciales alternativas para el servidor.

  Ejemplos
  --------
  # Panorama rápido: recursos y quién tiene permiso en la raíz de cada uno
  .\Get-PermisosCarpetasCompartidas.ps1 -Servidor \\10.10.1.65

  # Dos niveles de subcarpetas, resolviendo grupos a usuarios, con CSV
  .\Get-PermisosCarpetasCompartidas.ps1 -Servidor 10.10.1.65 -Profundidad 2 `
      -ExpandirGrupos -CarpetaSalida C:\Auditoria

  # ¿A qué carpetas llega un usuario concreto?
  .\Get-PermisosCarpetasCompartidas.ps1 -Servidor 10.10.1.65 -Profundidad 3 `
      -ExpandirGrupos -SoloUsuario '*jperez*'

  Nota sobre el acceso efectivo
  -----------------------------
  El acceso real a un recurso de red es la intersección del permiso de
  compartición (SMB) y el permiso NTFS, y las denegaciones (Deny) mandan sobre
  las concesiones. El informe muestra ambos orígenes por separado, en la
  columna 'Origen', para que esa intersección pueda revisarse.
=============================================================================
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Servidor,

    [string[]]$Recurso,

    [ValidateRange(0, 10)]
    [int]$Profundidad = 0,

    [string[]]$SoloUsuario,

    [switch]$IncluirRecursosAdministrativos,

    [switch]$IncluirHeredados,

    [switch]$IncluirCuentasSistema,

    [switch]$ExpandirGrupos,

    [string]$CarpetaSalida,

    [System.Management.Automation.PSCredential]$Credencial
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cuentas integradas que aparecen en casi toda ACL y solo añaden ruido.
$script:CuentasSistema = @(
    'NT AUTHORITY\SYSTEM'
    'NT AUTHORITY\SISTEMA'
    'BUILTIN\Administrators'
    'BUILTIN\Administradores'
    'CREATOR OWNER'
    'CREATOR GROUP'
    'CREADOR PROPIETARIO'
    'NT SERVICE\TrustedInstaller'
    'NT AUTHORITY\NETWORK SERVICE'
    'NT AUTHORITY\SERVICIO DE RED'
)

# Autoridades que nunca corresponden a personas y no tiene sentido expandir.
$script:AutoridadesNoExpandibles = @(
    'NT AUTHORITY'
    'NT SERVICE'
    'BUILTIN'
    'APPLICATION PACKAGE AUTHORITY'
)

$script:RecursosAdministrativos = @('ADMIN$', 'IPC$', 'print$', 'FAX$')

$script:SesionCim = $null
$script:ConexionIpc = $null
$script:CacheGrupos = @{}

#region Utilidades ----------------------------------------------------------

function Resolve-NombreEquipo {
    <# Acepta '\\10.10.1.65', '\\SRVFILES\Datos' o 'srvfiles' y devuelve el host. #>
    param([string]$Valor)

    $limpio = $Valor.Trim().Trim('\')
    if ([string]::IsNullOrWhiteSpace($limpio)) {
        throw "El parámetro -Servidor no contiene un nombre o IP válido."
    }
    return ($limpio -split '\\')[0]
}

function ConvertTo-PermisoLegible {
    <# Traduce la máscara FileSystemRights a los nombres del explorador de Windows.
       El parámetro no se tipa como FileSystemRights porque las ACL con derechos
       genéricos llevan bits que ese enumerado rechaza al convertir. #>
    param($Derechos)

    # Las ACL remotas pueden devolver derechos genéricos (GENERIC_READ y
    # compañía) que .NET no sabe nombrar; se normalizan a su equivalente NTFS.
    $valor = [int64]([int]$Derechos) -band 0xFFFFFFFFL
    $genericos = @{
        0x10000000L = 2032127L   # GENERIC_ALL     -> Control total
        0x20000000L = 131241L    # GENERIC_EXECUTE -> Lectura y ejecución
        0x40000000L = 278L       # GENERIC_WRITE   -> Escritura
        0x80000000L = 131209L    # GENERIC_READ    -> Lectura
    }
    foreach ($generico in $genericos.GetEnumerator()) {
        if ($valor -band $generico.Key) { $valor = $valor -bor $generico.Value }
    }

    $conjuntos = [ordered]@{
        'Control total'       = 2032127L
        'Modificar'           = 197055L
        'Lectura y ejecución' = 131241L
        'Lectura'             = 131209L
        'Escritura'           = 278L
    }
    foreach ($conjunto in $conjuntos.GetEnumerator()) {
        if (($valor -band $conjunto.Value) -eq $conjunto.Value) { return $conjunto.Name }
    }

    return "Especial ($Derechos)"
}

function Test-IdentidadFiltrada {
    <# Devuelve $true cuando la identidad no debe aparecer en el informe. #>
    param([string]$Identidad)

    if (-not $IncluirCuentasSistema -and $script:CuentasSistema -contains $Identidad) {
        return $true
    }
    if ($SoloUsuario) {
        foreach ($patron in $SoloUsuario) {
            if ($Identidad -like $patron) { return $false }
        }
        return $true
    }
    return $false
}

function Open-Conexion {
    <# Abre las conexiones al servidor: sesión CIM para enumerar recursos y, si se
       pasaron credenciales, un canal SMB autenticado para recorrer las rutas UNC. #>
    param([string]$Equipo)

    if ($Credencial) {
        $usuario = $Credencial.UserName
        $clave = $Credencial.GetNetworkCredential().Password
        $salida = & net.exe use "\\$Equipo\IPC$" $clave /user:$usuario 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "No se pudo autenticar contra \\$Equipo como '$usuario': $salida"
        }
        $script:ConexionIpc = "\\$Equipo\IPC$"
        Write-Verbose "Canal SMB autenticado con \\$Equipo como '$usuario'."
    }

    try {
        $parametros = @{ ComputerName = $Equipo; ErrorAction = 'Stop' }
        if ($Credencial) { $parametros.Credential = $Credencial }
        $script:SesionCim = New-CimSession @parametros
    }
    catch {
        Write-Warning "Sin sesión CIM/WMI contra $Equipo ($($_.Exception.Message)). Se usará solo SMB, sin permisos de compartición."
        $script:SesionCim = $null
    }
}

function Close-Conexion {
    if ($script:SesionCim) {
        Remove-CimSession -CimSession $script:SesionCim -ErrorAction SilentlyContinue
        $script:SesionCim = $null
    }
    if ($script:ConexionIpc) {
        & net.exe use $script:ConexionIpc /delete /y 2>&1 | Out-Null
        $script:ConexionIpc = $null
    }
}

#endregion

#region Recolección ---------------------------------------------------------

function Get-RecursoCompartido {
    <# Enumera los recursos publicados. Usa CIM y, si el servidor no responde por
       esa vía, cae a 'net view', que solo necesita SMB. #>
    param([string]$Equipo)

    $recursos = @()

    if ($script:SesionCim) {
        try {
            $recursos = @(Get-CimInstance -ClassName Win32_Share -CimSession $script:SesionCim -ErrorAction Stop |
                Select-Object @{ n = 'Nombre'; e = { $_.Name } },
                              @{ n = 'RutaLocal'; e = { $_.Path } },
                              @{ n = 'Descripcion'; e = { $_.Description } })
        }
        catch {
            Write-Warning "Win32_Share falló en $Equipo : $($_.Exception.Message)"
        }
    }

    if ($recursos.Count -eq 0) {
        Write-Verbose "Enumerando recursos con 'net view \\$Equipo'."
        $salida = & net.exe view "\\$Equipo" /all 2>&1
        $recursos = @($salida |
            Where-Object { $_ -match '^\S.*\s{2,}(Disk|Disco)\s*' } |
            ForEach-Object {
                [pscustomobject]@{
                    Nombre      = (($_ -split '\s{2,}')[0]).Trim()
                    RutaLocal   = $null
                    Descripcion = $null
                }
            })
    }

    if (-not $IncluirRecursosAdministrativos) {
        $recursos = @($recursos | Where-Object {
            $script:RecursosAdministrativos -notcontains $_.Nombre -and $_.Nombre -notmatch '^[A-Za-z]\$$'
        })
    }
    if ($Recurso) {
        $recursos = @($recursos | Where-Object {
            $nombre = $_.Nombre
            @($Recurso | Where-Object { $nombre -like $_ }).Count -gt 0
        })
    }

    return @($recursos | Sort-Object Nombre)
}

function Get-PermisoCompartido {
    <# Permisos del recurso compartido (pestaña 'Compartir'), no los NTFS. #>
    param([string]$NombreRecurso)

    if (-not $script:SesionCim) { return @() }

    try {
        return @(Get-SmbShareAccess -Name $NombreRecurso -CimSession $script:SesionCim -ErrorAction Stop |
            ForEach-Object {
                [pscustomobject]@{
                    Identidad  = $_.AccountName
                    Permiso    = switch ("$($_.AccessRight)") {
                                     'Full'   { 'Control total' }
                                     'Change' { 'Modificar' }
                                     'Read'   { 'Lectura' }
                                     default  { "$($_.AccessRight)" }
                                 }
                    TipoAcceso = "$($_.AccessControlType)"
                }
            })
    }
    catch {
        Write-Verbose "Sin permisos de compartición para '$NombreRecurso': $($_.Exception.Message)"
        return @()
    }
}

function Get-CarpetaAuditable {
    <# Devuelve la raíz del recurso más sus subcarpetas hasta -Profundidad. #>
    param([string]$RutaUnc)

    $carpetas = [System.Collections.Generic.List[string]]::new()
    $carpetas.Add($RutaUnc)

    if ($Profundidad -gt 0) {
        try {
            Get-ChildItem -LiteralPath $RutaUnc -Directory -Recurse -Depth ($Profundidad - 1) -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $carpetas.Add($_.FullName) }
        }
        catch {
            Write-Warning "No se pudieron listar subcarpetas de '$RutaUnc': $($_.Exception.Message)"
        }
    }
    return , $carpetas
}

function Get-PermisoNtfs {
    <# ACE NTFS de una carpeta concreta. #>
    param([string]$Ruta)

    try {
        $acl = Get-Acl -LiteralPath $Ruta -ErrorAction Stop
    }
    catch {
        Write-Warning "No se pudo leer la ACL de '$Ruta': $($_.Exception.Message)"
        return @()
    }

    $reglas = @($acl.Access | Where-Object { $IncluirHeredados -or -not $_.IsInherited })

    return @($reglas | ForEach-Object {
        [pscustomobject]@{
            Identidad   = $_.IdentityReference.Value
            Permiso     = ConvertTo-PermisoLegible -Derechos $_.FileSystemRights
            TipoAcceso  = "$($_.AccessControlType)"
            Heredado    = $_.IsInherited
            Propietario = $acl.Owner
        }
    })
}

function Expand-Grupo {
    <# Resuelve un grupo (de dominio o local) a sus usuarios, de forma recursiva.
       Usa el módulo ActiveDirectory si está presente y, si no, ADSI/WinNT.
       Devuelve una lista vacía cuando la identidad no es un grupo. #>
    param(
        [string]$Identidad,
        [System.Collections.Generic.HashSet[string]]$Visitados
    )

    if ($script:CacheGrupos.ContainsKey($Identidad)) { return $script:CacheGrupos[$Identidad] }
    if (-not $Visitados.Add($Identidad)) { return @() }   # corta ciclos de grupos anidados

    $partes = $Identidad -split '\\', 2
    if ($partes.Count -ne 2) { return @() }
    $dominio = $partes[0]
    $nombre = $partes[1]
    if ($script:AutoridadesNoExpandibles -contains $dominio.ToUpperInvariant()) { return @() }

    $miembros = [System.Collections.Generic.List[string]]::new()
    $resuelto = $false

    if (Get-Module -ListAvailable -Name ActiveDirectory) {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false
            Get-ADGroupMember -Identity $nombre -Recursive -ErrorAction Stop |
                ForEach-Object { $miembros.Add("$dominio\$($_.SamAccountName)") }
            $resuelto = $true
        }
        catch {
            Write-Verbose "ActiveDirectory no resolvió '$Identidad': $($_.Exception.Message)"
        }
    }

    if (-not $resuelto) {
        try {
            $grupo = [ADSI]"WinNT://$dominio/$nombre,group"
            foreach ($miembro in @($grupo.psbase.Invoke('Members'))) {
                $clase = $miembro.GetType().InvokeMember('Class', 'GetProperty', $null, $miembro, $null)
                $nombreMiembro = $miembro.GetType().InvokeMember('Name', 'GetProperty', $null, $miembro, $null)
                $rutaMiembro = $miembro.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $miembro, $null)
                $dominioMiembro = (($rutaMiembro -replace '^WinNT://', '') -split '/')[0]

                if ($clase -eq 'Group') {
                    foreach ($anidado in (Expand-Grupo -Identidad "$dominioMiembro\$nombreMiembro" -Visitados $Visitados)) {
                        $miembros.Add($anidado)
                    }
                }
                else {
                    $miembros.Add("$dominioMiembro\$nombreMiembro")
                }
            }
        }
        catch {
            Write-Verbose "ADSI no resolvió '$Identidad' (probablemente no es un grupo): $($_.Exception.Message)"
        }
    }

    $resultado = @($miembros | Sort-Object -Unique)
    $script:CacheGrupos[$Identidad] = $resultado
    return $resultado
}

function ConvertTo-FilaPermiso {
    param(
        [string]$Equipo,
        [psobject]$RecursoInfo,
        [string]$Ruta,
        [ValidateSet('Compartido', 'NTFS')][string]$Origen,
        [string]$Identidad,
        [object]$EsGrupo,
        [string]$ViaGrupo,
        [string]$Permiso,
        [string]$TipoAcceso,
        [object]$Heredado,
        [string]$Propietario
    )

    [pscustomobject]@{
        Servidor    = $Equipo
        Recurso     = $RecursoInfo.Nombre
        Ruta        = $Ruta
        RutaLocal   = $RecursoInfo.RutaLocal
        Origen      = $Origen
        Identidad   = $Identidad
        EsGrupo     = $EsGrupo
        ViaGrupo    = $ViaGrupo
        Permiso     = $Permiso
        TipoAcceso  = $TipoAcceso
        Heredado    = $Heredado
        Propietario = $Propietario
    }
}

#endregion

#region Ejecución -----------------------------------------------------------

$equipo = Resolve-NombreEquipo -Valor $Servidor
$filas = [System.Collections.Generic.List[psobject]]::new()

try {
    Open-Conexion -Equipo $equipo

    Write-Host "Auditando \\$equipo ..." -ForegroundColor Cyan
    $recursos = Get-RecursoCompartido -Equipo $equipo
    if ($recursos.Count -eq 0) {
        Write-Warning "No se encontraron recursos compartidos visibles en \\$equipo."
        return
    }
    Write-Host ("Recursos a revisar: {0}" -f $recursos.Count) -ForegroundColor Cyan

    foreach ($item in $recursos) {
        $rutaRecurso = "\\$equipo\$($item.Nombre)"
        Write-Host "  -> $rutaRecurso" -ForegroundColor DarkCyan

        # 1) Permisos de compartición: aplican a todo el árbol del recurso.
        foreach ($ace in Get-PermisoCompartido -NombreRecurso $item.Nombre) {
            if (Test-IdentidadFiltrada -Identidad $ace.Identidad) { continue }
            $filas.Add((ConvertTo-FilaPermiso -Equipo $equipo -RecursoInfo $item -Ruta $rutaRecurso `
                        -Origen 'Compartido' -Identidad $ace.Identidad -EsGrupo $null -ViaGrupo $null `
                        -Permiso $ace.Permiso -TipoAcceso $ace.TipoAcceso -Heredado $false -Propietario $null))
        }

        # 2) Permisos NTFS de la raíz y de las subcarpetas solicitadas.
        foreach ($carpeta in Get-CarpetaAuditable -RutaUnc $rutaRecurso) {
            foreach ($ace in Get-PermisoNtfs -Ruta $carpeta) {
                $miembros = @()
                $esGrupo = $null
                if ($ExpandirGrupos) {
                    $visitados = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $miembros = @(Expand-Grupo -Identidad $ace.Identidad -Visitados $visitados)
                    $esGrupo = ($miembros.Count -gt 0)
                }

                if (-not (Test-IdentidadFiltrada -Identidad $ace.Identidad)) {
                    $filas.Add((ConvertTo-FilaPermiso -Equipo $equipo -RecursoInfo $item -Ruta $carpeta `
                                -Origen 'NTFS' -Identidad $ace.Identidad -EsGrupo $esGrupo -ViaGrupo $null `
                                -Permiso $ace.Permiso -TipoAcceso $ace.TipoAcceso -Heredado $ace.Heredado `
                                -Propietario $ace.Propietario))
                }

                # Cada miembro del grupo se añade como fila propia para que el
                # informe por usuario refleje el acceso real de las personas.
                foreach ($miembro in $miembros) {
                    if (Test-IdentidadFiltrada -Identidad $miembro) { continue }
                    $filas.Add((ConvertTo-FilaPermiso -Equipo $equipo -RecursoInfo $item -Ruta $carpeta `
                                -Origen 'NTFS' -Identidad $miembro -EsGrupo $false -ViaGrupo $ace.Identidad `
                                -Permiso $ace.Permiso -TipoAcceso $ace.TipoAcceso -Heredado $ace.Heredado `
                                -Propietario $ace.Propietario))
                }
            }
        }
    }
}
finally {
    Close-Conexion
}

if ($filas.Count -eq 0) {
    Write-Warning "No se obtuvo ningún permiso. Revise credenciales, filtros (-SoloUsuario) y conectividad."
    return
}

#endregion

#region Informes ------------------------------------------------------------

$detalle = @($filas | Sort-Object Recurso, Ruta, Identidad)

$porUsuario = @($detalle |
    Group-Object Identidad |
    ForEach-Object {
        [pscustomobject]@{
            Identidad = $_.Name
            Carpetas  = @($_.Group.Ruta | Sort-Object -Unique).Count
            Permisos  = (@($_.Group.Permiso | Sort-Object -Unique) -join ', ')
            Rutas     = (@($_.Group.Ruta | Sort-Object -Unique) -join '; ')
        }
    } |
    Sort-Object Identidad)

Write-Host "`n=== PERMISOS POR CARPETA ===" -ForegroundColor Green
$detalle |
    Format-Table Ruta, Origen, Identidad, ViaGrupo, Permiso, TipoAcceso, Heredado -AutoSize |
    Out-String -Width 4096 |
    Write-Host

Write-Host "=== CARPETAS POR USUARIO O GRUPO ===" -ForegroundColor Green
$porUsuario |
    Format-Table Identidad, Carpetas, Permisos -AutoSize |
    Out-String -Width 4096 |
    Write-Host

if ($CarpetaSalida) {
    if (-not (Test-Path -LiteralPath $CarpetaSalida)) {
        New-Item -Path $CarpetaSalida -ItemType Directory -Force | Out-Null
    }
    $marca = Get-Date -Format 'yyyyMMdd_HHmmss'
    $csvDetalle = Join-Path $CarpetaSalida "Permisos_Detalle_${equipo}_$marca.csv"
    $csvUsuario = Join-Path $CarpetaSalida "Permisos_PorUsuario_${equipo}_$marca.csv"

    $detalle | Export-Csv -Path $csvDetalle -NoTypeInformation -Encoding UTF8
    $porUsuario | Export-Csv -Path $csvUsuario -NoTypeInformation -Encoding UTF8

    Write-Host "Informe detallado  : $csvDetalle" -ForegroundColor Yellow
    Write-Host "Informe por usuario: $csvUsuario" -ForegroundColor Yellow
}

# El detalle se devuelve al pipeline para poder encadenar filtros:
#   .\Get-PermisosCarpetasCompartidas.ps1 -Servidor 10.10.1.65 |
#       Where-Object { $_.Permiso -eq 'Control total' }
$detalle

#endregion
