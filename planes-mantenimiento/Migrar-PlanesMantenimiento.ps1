<#
.SYNOPSIS
    Migra planes de mantenimiento completos (paquete + subplanes + jobs + horarios)
    de un servidor SQL Server a otro, sin dtutil ni SSMS.

.DESCRIPTION
    Por cada plan de la carpeta "Maintenance Plans" del servidor origen (o solo los de -Planes):
      1. Lee el paquete del plan (msdb.dbo.sysssispackages) y guarda una copia .dtsx.
      2. Cambia la conexion "Local server connection" del origen al destino.
      3. Revisa rutas de backup/reportes y verifica que existan en el destino.
      4. Crea en el destino, en UNA transaccion por plan:
           - el paquete del plan (mismo id),
           - los jobs de cada subplan (pasos, horarios, categoria, operador),
           - el registro de subplanes (lo mismo que hace SSMS al guardar el plan).
      5. Deja los jobs DESHABILITADOS en el destino (se activan el dia del failover).

.EXAMPLE
    .\Migrar-PlanesMantenimiento.ps1 -SoloRevisar                  # solo analiza, no escribe nada
    .\Migrar-PlanesMantenimiento.ps1                               # migra todos los planes de tanatos a hermes
    .\Migrar-PlanesMantenimiento.ps1 -Reemplazar                   # vuelve a migrar los que ya existan
    .\Migrar-PlanesMantenimiento.ps1 -Origen eros -Destino hermes  # todos los planes de eros
    .\Migrar-PlanesMantenimiento.ps1 -Planes 'Tanatos Backup Diario Full','Tanatos Consistencia Semanal'
#>
param(
    [string]$Origen  = 'tanatos',
    [string]$Destino = 'hermes',
    # Por defecto TODOS los planes de "Maintenance Plans". Opcional: nombres exactos o con * (ej. 'Eros*').
    [string[]]$Planes = @('*'),
    [string]$Carpeta = 'C:\temp\sync_planes',
    [switch]$SoloRevisar,
    [switch]$Reemplazar,
    [switch]$JobsActivos,
    [pscredential]$Credencial
)

$ErrorActionPreference = 'Stop'
$CarpetaPlanes = '08AA12D5-8F98-4DAB-A4FC-980B150A5DC8'

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null
$log = Join-Path $Carpeta ("planes_{0}_{1}.log" -f ($Destino -replace '[\\/:*?"<>|,]', '_'), $stamp)
Start-Transcript -Path $log | Out-Null

$script:Atencion = New-Object System.Collections.Generic.List[string]
$script:Errores  = New-Object System.Collections.Generic.List[string]
function Write-Atencion([string]$m) { $script:Atencion.Add($m); Write-Host "  ATENCION: $m" -ForegroundColor Yellow }
function Write-Error2([string]$m)   { $script:Errores.Add($m);  Write-Host "  ERROR: $m" -ForegroundColor Red }
function V($x) { if ($x -is [DBNull]) { $null } else { $x } }

function Open-Sql([string]$server) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $server
    $b['Initial Catalog'] = 'msdb'
    $b['Application Name'] = 'Migrar-PlanesMantenimiento'
    $b['TrustServerCertificate'] = $true
    if ($Credencial) {
        $b['User ID']  = $Credencial.UserName
        $b['Password'] = $Credencial.GetNetworkCredential().Password
    } else {
        $b['Integrated Security'] = $true
    }
    $c = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    $c.Open()
    $c
}

function Invoke-Sql($conn, [string]$sql, [hashtable]$p = @{}, $tran = $null) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = 300
    if ($tran) { $cmd.Transaction = $tran }
    foreach ($k in $p.Keys) {
        $v = $p[$k]
        if ($null -eq $v) { $v = [DBNull]::Value }
        [void]$cmd.Parameters.AddWithValue("@$k", $v)
    }
    $dt = New-Object System.Data.DataTable
    $rd = $cmd.ExecuteReader()
    try { $dt.Load($rd) } finally { $rd.Close() }
    $dt.Rows
}

function Read-PackageText([byte[]]$b) {
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        return @{ Enc = (New-Object System.Text.UTF8Encoding($true)); Text = [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
    }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) {
        return @{ Enc = (New-Object System.Text.UnicodeEncoding($false, $true)); Text = [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    }
    return @{ Enc = (New-Object System.Text.UTF8Encoding($false)); Text = [Text.Encoding]::UTF8.GetString($b) }
}

function Test-PlanPedido([string]$n, [string]$p) {
    if ($p.Contains('*')) { return ($n -like $p) }
    return ($n -eq $p.Trim())
}

function Test-RutaDestino($conn, [string]$ruta) {
    try {
        $r = @(Invoke-Sql $conn @"
DECLARE @t TABLE (fe INT, isdir INT, parent INT);
INSERT @t EXEC master.dbo.xp_fileexist @p;
SELECT fe, isdir, parent FROM @t;
"@ @{ p = $ruta })[0]
        return ($r.fe -eq 1 -or $r.isdir -eq 1)
    } catch { return $null }
}

# ---------------------------------------------------------------- conexion
Write-Host "Origen : $Origen" -ForegroundColor Cyan
Write-Host "Destino: $Destino" -ForegroundColor Cyan
Write-Host "Planes : $($Planes -join ' | ')" -ForegroundColor Cyan
if ($SoloRevisar) { Write-Host "MODO SOLO REVISION: no se escribe nada en $Destino" -ForegroundColor Magenta }

try {
    $src = Open-Sql $Origen
    $dst = Open-Sql $Destino
} catch {
    Write-Host "ERROR de conexion: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

$qInfo = "SELECT @@SERVERNAME AS n, CONVERT(nvarchar(30), SERVERPROPERTY('ProductVersion')) AS v, IS_SRVROLEMEMBER('sysadmin') AS sa"
$infoSrc = @(Invoke-Sql $src $qInfo)[0]
$infoDst = @(Invoke-Sql $dst $qInfo)[0]
Write-Host ("  {0} = {1} ({2})" -f $Origen,  $infoSrc.n, $infoSrc.v)
Write-Host ("  {0} = {1} ({2})" -f $Destino, $infoDst.n, $infoDst.v)
if ($infoSrc.sa -ne 1 -or $infoDst.sa -ne 1) {
    Write-Host "ERROR: se requiere sysadmin en ambos servidores." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

$nombreDestino = [string]$infoDst.n
$nombresOrigen = @([string]$infoSrc.n, $Origen) |
    Where-Object { $_ -and $_ -notmatch '[,:]' } |
    Sort-Object -Property Length -Descending -Unique
$alt = ($nombresOrigen | ForEach-Object { [regex]::Escape($_) }) -join '|'
$mismoNombre = ([string]$infoSrc.n -eq $nombreDestino)
if ($mismoNombre) { Write-Atencion "Ambos servidores tienen @@SERVERNAME = $nombreDestino; no se cambia la conexion de los planes." }

$qPerfiles = "SELECT COUNT(*) AS c FROM msdb.dbo.sysmail_profile"
if (@(Invoke-Sql $src $qPerfiles)[0].c -gt 0 -and @(Invoke-Sql $dst $qPerfiles)[0].c -eq 0) {
    Write-Atencion "Database Mail no tiene perfiles en $Destino; los jobs no enviaran correos hasta configurarlo."
}

$rxConexion = "(?i)(?<=(?:SqlServerName|Data Source|Server)=)(?:$alt)(?=[;`"&<])"
$rxPaso     = "(?i)(?<=/SERVER\s+`"?)(?:$alt)(?=[`"\s]|$)"
$rxResto    = "(?i)(?<![\w-])(?:$alt)(?![\w-])"
$rxRutas    = '(?i)(?:\b[A-Z]:\\|\\\\)[^"&<>|]*'

# ---------------------------------------------------------------- planes
$todos = @(Invoke-Sql $src @"
SELECT name, id, description, createdate, packagedata, packageformat, packagetype,
       vermajor, verminor, verbuild, vercomments, verid
FROM msdb.dbo.sysssispackages
WHERE folderid = @f AND packagetype = 6
ORDER BY name;
"@ @{ f = [Guid]$CarpetaPlanes })

$aMigrar = @($todos | Where-Object { $n = [string]$_.name; @($Planes | Where-Object { Test-PlanPedido $n $_ }).Count -gt 0 })
foreach ($p in $Planes) {
    if (@($todos | Where-Object { Test-PlanPedido ([string]$_.name) $p }).Count -eq 0) {
        Write-Atencion "El plan '$p' no existe en $Origen (revise el nombre)."
    }
}
if ($aMigrar.Count -eq 0) {
    Write-Host "Ninguno de los planes indicados existe en $Origen. Planes disponibles:" -ForegroundColor Yellow
    $todos | ForEach-Object { Write-Host "  $($_.name)" }
    Stop-Transcript | Out-Null
    exit 1
}
Write-Host ("Planes a migrar: {0}" -f $aMigrar.Count) -ForegroundColor Cyan
$aMigrar | ForEach-Object { Write-Host "  $($_.name)" }

$resumen = New-Object System.Collections.Generic.List[object]

foreach ($pl in $aMigrar) {
    $nombre = [string]$pl.name
    $planId = [Guid]$pl.id
    Write-Host ""
    Write-Host "=== $nombre" -ForegroundColor Cyan
    $estado = 'MIGRADO'
    $archivo = Join-Path $Carpeta (($nombre -replace '[\\/:*?"<>|]', '_') + "_$stamp")

    # --- paquete: conexion y rutas
    [byte[]]$bytes = $pl.packagedata
    [IO.File]::WriteAllBytes("$archivo.original.dtsx", $bytes)
    $pkg = Read-PackageText $bytes
    $texto = $pkg.Text
    $nConex = 0
    if (-not $mismoNombre) {
        $nConex = [regex]::Matches($texto, $rxConexion).Count
        $texto  = [regex]::Replace($texto, $rxConexion, $nombreDestino)
    }
    $conexiones = [regex]::Matches($texto, '(?i)(?:SqlServerName|Data Source)=[^;"&]*') | ForEach-Object { $_.Value } | Sort-Object -Unique
    Write-Host ("  Conexion: {0} reemplazo(s) -> {1}" -f $nConex, ($conexiones -join ', '))
    if ($nConex -eq 0 -and -not $mismoNombre) {
        Write-Atencion "[$nombre] no se encontro '$($nombresOrigen -join '/')' en la conexion del plan; revise la conexion en SSMS."
    }
    if ($nConex -gt 0) {
        $nuevo = [byte[]]($pkg.Enc.GetPreamble() + $pkg.Enc.GetBytes($texto))
        [IO.File]::WriteAllBytes("$archivo.$($Destino -replace '[\\/:*?"<>|,]', '_').dtsx", $nuevo)
    } else {
        $nuevo = $bytes
    }
    if (-not $mismoNombre) {
        # Metadatos sin efecto en la ejecucion (equipo creador, descripcion, nombres de objetos).
        $sinNombre = [regex]::Replace($texto, '(?i)' + [regex]::Escape($nombre), '')
        $sinNombre = [regex]::Replace($sinNombre, '(?i)\b(?:DTS:)?(?:CreatorComputerName|CreatorName|Description|ObjectName)="[^"]*"', '')
        $vistos = @{}
        foreach ($m in [regex]::Matches($sinNombre, $rxResto)) {
            $ini = [Math]::Max(0, $m.Index - 40)
            $ctx = $sinNombre.Substring($ini, [Math]::Min(100, $sinNombre.Length - $ini)) -replace '\s+', ' '
            if ($vistos.ContainsKey($ctx)) { continue }
            $vistos[$ctx] = 1
            Write-Atencion "[$nombre] el plan aun menciona '$($m.Value)': ...$ctx..."
        }
    }

    # --- subplanes y jobs del origen
    $subplanes = @(Invoke-Sql $src @"
SELECT s.subplan_id, s.subplan_name, s.subplan_description, s.schedule_id, j.job_id, j.name AS job_name,
       j.enabled, j.description, c.name AS category, SUSER_SNAME(j.owner_sid) AS owner,
       j.notify_level_eventlog, j.notify_level_email, o.name AS email_operator, j.delete_level, j.start_step_id
FROM msdb.dbo.sysmaintplan_subplans s
JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id
LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
LEFT JOIN msdb.dbo.sysoperators  o ON o.id = j.notify_email_operator_id
WHERE s.plan_id = @id
ORDER BY s.subplan_name;
"@ @{ id = $planId })
    Write-Host ("  Subplanes: {0}" -f (($subplanes | ForEach-Object { "$($_.subplan_name) [$($_.job_name)]" }) -join ', '))
    if ($subplanes.Count -eq 0) { Write-Atencion "[$nombre] no tiene subplanes con job en $Origen; solo se copia el paquete." }

    $rutas = New-Object System.Collections.Generic.List[string]
    [regex]::Matches($texto, $rxRutas) | ForEach-Object { $rutas.Add($_.Value.TrimEnd()) }
    $jobs = @()
    foreach ($sp in $subplanes) {
        $pasos = @(Invoke-Sql $src @"
SELECT s.step_id, s.step_name, s.subsystem, s.command, s.cmdexec_success_code, s.on_success_action, s.on_success_step_id,
       s.on_fail_action, s.on_fail_step_id, s.database_name, s.database_user_name, s.retry_attempts, s.retry_interval,
       s.output_file_name, s.flags, p.name AS proxy
FROM msdb.dbo.sysjobsteps s LEFT JOIN msdb.dbo.sysproxies p ON p.proxy_id = s.proxy_id
WHERE s.job_id = @id ORDER BY s.step_id;
"@ @{ id = [Guid]$sp.job_id })
        $horarios = @(Invoke-Sql $src @"
SELECT sc.schedule_id, sc.name, sc.enabled, sc.freq_type, sc.freq_interval, sc.freq_subday_type, sc.freq_subday_interval,
       sc.freq_relative_interval, sc.freq_recurrence_factor, sc.active_start_date, sc.active_end_date,
       sc.active_start_time, sc.active_end_time
FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = js.schedule_id
WHERE js.job_id = @id;
"@ @{ id = [Guid]$sp.job_id })
        foreach ($ps in $pasos) {
            $of = V $ps.output_file_name
            if ($of) { $rutas.Add($of) }
        }
        $jobs += [pscustomobject]@{ Sub = $sp; Pasos = $pasos; Horarios = $horarios }
    }
    foreach ($ruta in ($rutas | Sort-Object -Unique)) {
        $ok = Test-RutaDestino $dst $ruta
        if ($ok -eq $true) { Write-Host "  Ruta OK en ${Destino}: $ruta" -ForegroundColor DarkGray }
        elseif ($ok -eq $false) { Write-Atencion "[$nombre] la ruta no existe (o no es accesible) para SQL Server en ${Destino}: $ruta" }
        else { Write-Atencion "[$nombre] no se pudo verificar la ruta en ${Destino}: $ruta" }
    }

    # --- conflictos en el destino
    $existe = @(Invoke-Sql $dst "SELECT id FROM msdb.dbo.sysssispackages WHERE folderid = @f AND name = @n" @{ f = [Guid]$CarpetaPlanes; n = $nombre })
    $idOcupado = @(Invoke-Sql $dst "SELECT name FROM msdb.dbo.sysssispackages WHERE id = @id AND NOT (folderid = @f AND name = @n)" @{ id = $planId; f = [Guid]$CarpetaPlanes; n = $nombre })
    $jobsExistentes = @()
    foreach ($j in $jobs) {
        if (@(Invoke-Sql $dst "SELECT 1 AS x FROM msdb.dbo.sysjobs WHERE name = @n" @{ n = [string]$j.Sub.job_name }).Count -gt 0) {
            $jobsExistentes += [string]$j.Sub.job_name
        }
    }
    if ($idOcupado.Count -gt 0) {
        Write-Error2 "[$nombre] en $Destino ya hay otro paquete con el mismo id ($($idOcupado[0].name)); se omite."
        $resumen.Add([pscustomobject]@{ Plan = $nombre; Estado = 'ERROR'; Subplanes = $subplanes.Count; Conexion = $nConex })
        continue
    }
    if (($existe.Count -gt 0 -or $jobsExistentes.Count -gt 0) -and -not $Reemplazar) {
        if ($existe.Count -gt 0) {
            Write-Atencion "[$nombre] el plan ya existe en $Destino. Use -Reemplazar para volver a migrarlo."
        } else {
            Write-Atencion "[$nombre] el plan NO existe en $Destino, pero ya hay jobs con el mismo nombre (copiados sin el plan): $($jobsExistentes -join ', '). Use -Reemplazar para recrearlos junto con el plan."
        }
        $resumen.Add([pscustomobject]@{ Plan = $nombre; Estado = 'OMITIDO (existe)'; Subplanes = $subplanes.Count; Conexion = $nConex })
        continue
    }

    if ($SoloRevisar) {
        $accion = 'SE CREARIA'; if ($existe.Count -gt 0 -or $jobsExistentes.Count -gt 0) { $accion = 'SE REEMPLAZARIA' }
        $resumen.Add([pscustomobject]@{ Plan = $nombre; Estado = $accion; Subplanes = $subplanes.Count; Conexion = $nConex })
        continue
    }

    # --- escritura en el destino (una transaccion por plan)
    $tran = $dst.BeginTransaction()
    try {
        if ($existe.Count -gt 0) {
            $idDst = [Guid]$existe[0].id
            Invoke-Sql $dst "EXEC msdb.dbo.sp_maintplan_delete_plan @plan_id = @id;" @{ id = $idDst } $tran | Out-Null
            Invoke-Sql $dst "DELETE msdb.dbo.sysssispackages WHERE folderid = @f AND name = @n;" @{ f = [Guid]$CarpetaPlanes; n = $nombre } $tran | Out-Null
            Write-Host "  Plan anterior eliminado en $Destino (con sus jobs)." -ForegroundColor DarkYellow
        }
        foreach ($jn in $jobsExistentes) {
            Invoke-Sql $dst @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @n)
BEGIN
    DELETE s FROM msdb.dbo.sysmaintplan_subplans s JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id WHERE j.name = @n;
    EXEC msdb.dbo.sp_delete_job @job_name = @n, @delete_unused_schedule = 1;
END
"@ @{ n = $jn } $tran | Out-Null
        }

        Invoke-Sql $dst @"
DECLARE @rc INT;
EXEC @rc = msdb.dbo.sp_ssis_putpackage @name = @name, @id = @id, @description = @description, @createdate = @createdate,
     @folderid = @folderid, @packagedata = @packagedata, @packageformat = @packageformat, @packagetype = @packagetype,
     @vermajor = @vermajor, @verminor = @verminor, @verbuild = @verbuild, @vercomments = @vercomments, @verid = @verid;
IF @rc <> 0 RAISERROR('sp_ssis_putpackage devolvio %d', 16, 1, @rc);
"@ @{ name = $nombre; id = $planId; description = (V $pl.description); createdate = $pl.createdate; folderid = [Guid]$CarpetaPlanes
      packagedata = $nuevo; packageformat = $pl.packageformat; packagetype = $pl.packagetype; vermajor = $pl.vermajor
      verminor = $pl.verminor; verbuild = $pl.verbuild; vercomments = (V $pl.vercomments); verid = [Guid]$pl.verid } $tran | Out-Null

        foreach ($j in $jobs) {
            $sp = $j.Sub
            $owner = V $sp.owner
            if (-not $owner -or @(Invoke-Sql $dst "SELECT 1 AS x WHERE SUSER_ID(@n) IS NOT NULL" @{ n = $owner } $tran).Count -eq 0) {
                $nuevoOwner = [string]@(Invoke-Sql $dst "SELECT SUSER_SNAME(0x01) AS n" @{} $tran)[0].n
                Write-Atencion "[$($sp.job_name)] el owner '$owner' no existe en $Destino; se usa '$nuevoOwner'."
                $owner = $nuevoOwner
            }
            $cat = V $sp.category
            if ($cat) {
                Invoke-Sql $dst @"
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = @c AND category_class = 1)
    EXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = @c;
"@ @{ c = $cat } $tran | Out-Null
            }
            $op = V $sp.email_operator
            $nivelMail = $sp.notify_level_email
            if ($op -and @(Invoke-Sql $dst "SELECT 1 AS x FROM msdb.dbo.sysoperators WHERE name = @n" @{ n = $op } $tran).Count -eq 0) {
                $o = @(Invoke-Sql $src "SELECT enabled, email_address, pager_address, netsend_address FROM msdb.dbo.sysoperators WHERE name = @n" @{ n = $op })
                if ($o.Count -gt 0) {
                    Invoke-Sql $dst @"
EXEC msdb.dbo.sp_add_operator @name = @n, @enabled = @e, @email_address = @m, @pager_address = @p, @netsend_address = @ns;
"@ @{ n = $op; e = $o[0].enabled; m = (V $o[0].email_address); p = (V $o[0].pager_address); ns = (V $o[0].netsend_address) } $tran | Out-Null
                    Write-Host "  Operador '$op' creado en $Destino ($(V $o[0].email_address))" -ForegroundColor Green
                } else {
                    Write-Atencion "[$($sp.job_name)] el operador '$op' no existe en $Destino; el job queda sin notificacion por correo."
                    $op = $null; $nivelMail = 0
                }
            }
            if (-not $op) { $nivelMail = 0 }
            $activo = 0; if ($JobsActivos) { $activo = $sp.enabled }

            $jobId = [Guid]@(Invoke-Sql $dst @"
DECLARE @job_id UNIQUEIDENTIFIER, @rc INT;
EXEC @rc = msdb.dbo.sp_add_job @job_name = @name, @enabled = @enabled, @description = @description,
     @category_name = @category, @owner_login_name = @owner, @notify_level_eventlog = @nle,
     @notify_level_email = @nlm, @notify_email_operator_name = @op, @delete_level = @dl, @job_id = @job_id OUTPUT;
IF @rc <> 0 RAISERROR('sp_add_job devolvio %d', 16, 1, @rc);
EXEC msdb.dbo.sp_add_jobserver @job_id = @job_id, @server_name = N'(local)';
SELECT @job_id AS job_id;
"@ @{ name = [string]$sp.job_name; enabled = $activo; description = (V $sp.description); category = $cat; owner = $owner
      nle = $sp.notify_level_eventlog; nlm = $nivelMail; op = $op; dl = $sp.delete_level } $tran)[0].job_id

            foreach ($ps in $j.Pasos) {
                $cmdPaso = [string](V $ps.command)
                if (-not $mismoNombre) { $cmdPaso = [regex]::Replace($cmdPaso, $rxPaso, $nombreDestino) }
                $proxy = V $ps.proxy
                if ($proxy -and @(Invoke-Sql $dst "SELECT 1 AS x FROM msdb.dbo.sysproxies WHERE name = @n" @{ n = $proxy } $tran).Count -eq 0) {
                    Write-Atencion "[$($sp.job_name)] el proxy '$proxy' no existe en $Destino; el paso se ejecutara con la cuenta del Agente."
                    $proxy = $null
                }
                Invoke-Sql $dst @"
EXEC msdb.dbo.sp_add_jobstep @job_id = @job_id, @step_id = @step_id, @step_name = @step_name, @subsystem = @subsystem,
     @command = @command, @cmdexec_success_code = @csc, @database_name = @db, @database_user_name = @dbu,
     @retry_attempts = @ra, @retry_interval = @ri, @output_file_name = @of, @flags = @flags, @proxy_name = @proxy;
"@ @{ job_id = $jobId; step_id = $ps.step_id; step_name = [string]$ps.step_name; subsystem = [string]$ps.subsystem
      command = $cmdPaso; csc = $ps.cmdexec_success_code; db = (V $ps.database_name); dbu = (V $ps.database_user_name)
      ra = $ps.retry_attempts; ri = $ps.retry_interval; of = (V $ps.output_file_name); flags = $ps.flags; proxy = $proxy } $tran | Out-Null
                $lineas = @($cmdPaso -split "`r?`n")
                $resumenPaso = $lineas[0]
                if ($lineas.Count -gt 1) { $resumenPaso += " ... ($($lineas.Count) lineas)" }
                Write-Host ("  Paso {0} [{1}]: {2}" -f $ps.step_id, $ps.subsystem, $resumenPaso) -ForegroundColor DarkGray
            }
            foreach ($ps in $j.Pasos) {
                Invoke-Sql $dst @"
EXEC msdb.dbo.sp_update_jobstep @job_id = @job_id, @step_id = @step_id, @on_success_action = @osa, @on_success_step_id = @oss,
     @on_fail_action = @ofa, @on_fail_step_id = @ofs;
"@ @{ job_id = $jobId; step_id = $ps.step_id; osa = $ps.on_success_action; oss = $ps.on_success_step_id
      ofa = $ps.on_fail_action; ofs = $ps.on_fail_step_id } $tran | Out-Null
            }
            if ($j.Pasos.Count -gt 0) {
                Invoke-Sql $dst "EXEC msdb.dbo.sp_update_job @job_id = @job_id, @start_step_id = @s;" @{ job_id = $jobId; s = $sp.start_step_id } $tran | Out-Null
            }

            $horarioSubplan = $null
            foreach ($h in $j.Horarios) {
                $idHorario = [int]@(Invoke-Sql $dst @"
DECLARE @schedule_id INT, @rc INT;
EXEC @rc = msdb.dbo.sp_add_jobschedule @job_id = @job_id, @name = @name, @enabled = @enabled, @freq_type = @ft,
     @freq_interval = @fi, @freq_subday_type = @fst, @freq_subday_interval = @fsi, @freq_relative_interval = @fri,
     @freq_recurrence_factor = @frf, @active_start_date = @asd, @active_end_date = @aed,
     @active_start_time = @ast, @active_end_time = @aet, @schedule_id = @schedule_id OUTPUT;
IF @rc <> 0 RAISERROR('sp_add_jobschedule devolvio %d', 16, 1, @rc);
SELECT @schedule_id AS schedule_id;
"@ @{ job_id = $jobId; name = [string]$h.name; enabled = $h.enabled; ft = $h.freq_type; fi = $h.freq_interval
      fst = $h.freq_subday_type; fsi = $h.freq_subday_interval; fri = $h.freq_relative_interval; frf = $h.freq_recurrence_factor
      asd = $h.active_start_date; aed = $h.active_end_date; ast = $h.active_start_time; aet = $h.active_end_time } $tran)[0].schedule_id
                if ((V $sp.schedule_id) -eq $h.schedule_id) { $horarioSubplan = $idHorario }
            }

            Invoke-Sql $dst @"
DECLARE @rc INT;
EXEC @rc = msdb.dbo.sp_maintplan_update_subplan @subplan_id = @subplan_id, @plan_id = @plan_id, @name = @name,
     @description = @description, @job_id = @job_id, @schedule_id = @schedule_id, @allow_create = 1;
IF @rc <> 0 RAISERROR('sp_maintplan_update_subplan devolvio %d', 16, 1, @rc);
"@ @{ subplan_id = [Guid]$sp.subplan_id; plan_id = $planId; name = [string]$sp.subplan_name
      description = (V $sp.subplan_description); job_id = $jobId; schedule_id = $horarioSubplan } $tran | Out-Null

            $txtActivo = 'DESHABILITADO'; if ($activo -eq 1) { $txtActivo = 'habilitado' }
            Write-Host ("  Job creado: {0} ({1}, {2} horario(s))" -f $sp.job_name, $txtActivo, $j.Horarios.Count) -ForegroundColor Green
        }
        $tran.Commit()
        if ($existe.Count -gt 0 -or $jobsExistentes.Count -gt 0) { $estado = 'REEMPLAZADO' }
    } catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        try { $tran.Rollback() } catch { }
        Write-Error2 "[$nombre] $($ex.Message) (no se aplico ningun cambio de este plan)"
        $estado = 'ERROR'
    }
    $resumen.Add([pscustomobject]@{ Plan = $nombre; Estado = $estado; Subplanes = $subplanes.Count; Conexion = $nConex })
}

# ---------------------------------------------------------------- resumen
Write-Host ""
Write-Host "===== RESUMEN =====" -ForegroundColor Cyan
$resumen | Format-Table -AutoSize | Out-String | Write-Host

if (-not $SoloRevisar) {
    Write-Host "Estado en ${Destino}:" -ForegroundColor Cyan
    $pedidos = @{}; $listaIn = @()
    $i = 0
    foreach ($pl in $aMigrar) { $pedidos["n$i"] = [string]$pl.name; $listaIn += "@n$i"; $i++ }
    Invoke-Sql $dst @"
SELECT p.name AS [Plan], s.subplan_name AS Subplan, j.name AS Job,
       CASE j.enabled WHEN 1 THEN 'SI' ELSE 'NO' END AS JobActivo, sc.name AS Horario,
       CASE WHEN st.command LIKE '%/SERVER%' THEN SUBSTRING(st.command, CHARINDEX('/SERVER', st.command), 30) ELSE '' END AS ServidorPaso
FROM msdb.dbo.sysmaintplan_plans p
JOIN msdb.dbo.sysmaintplan_subplans s ON s.plan_id = p.id
JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id
LEFT JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = s.schedule_id
LEFT JOIN msdb.dbo.sysjobsteps st ON st.job_id = j.job_id AND st.step_id = 1
WHERE p.name IN ($($listaIn -join ', '))
ORDER BY 1, 2;
"@ $pedidos | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
}

Write-Host ("Errores  : {0}" -f $script:Errores.Count)  -ForegroundColor $(if ($script:Errores.Count)  { 'Red' }    else { 'Green' })
Write-Host ("ATENCION : {0}" -f $script:Atencion.Count) -ForegroundColor $(if ($script:Atencion.Count) { 'Yellow' } else { 'Green' })
$script:Atencion | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
$script:Errores  | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
Write-Host ""
Write-Host "Copias .dtsx y log en: $Carpeta"
Write-Host "Log: $log"

$src.Close(); $dst.Close()
Stop-Transcript | Out-Null
if ($script:Errores.Count -gt 0) { exit 1 } else { exit 0 }
