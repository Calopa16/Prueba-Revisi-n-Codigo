<#
.SYNOPSIS
    Migra la configuracion de Database Mail de un servidor SQL Server a otro.

.DESCRIPTION
    Copia del origen al destino:
      - Cuentas SMTP (correo, nombre visible, reply-to, servidor, puerto, SSL, usuario).
      - Perfiles y el orden de sus cuentas.
      - Perfiles publicos / por defecto (sysmail_principalprofile).
      - Parametros del sistema (tamano maximo de adjuntos, reintentos, etc.).
      - Perfil de correo del SQL Server Agent (Alert System).
    Activa "Database Mail XPs" en el destino si esta apagado.

    La contrasena SMTP NO se puede leer del origen (SQL Server la guarda cifrada):
    el script la pide una vez por usuario SMTP, o se pasa con -PasswordSmtp.

.EXAMPLE
    .\Migrar-DatabaseMail.ps1 -Origen eros -Destino peon -SoloRevisar
    .\Migrar-DatabaseMail.ps1 -Origen eros -Destino peon -CorreoPrueba dba@comfamiliarhuila.com
    .\Migrar-DatabaseMail.ps1 -Origen eros -Destino peon -Reemplazar
#>
param(
    [string]$Origen  = 'tanatos',
    [string]$Destino = 'hermes',
    [string]$Carpeta = 'C:\temp\sync_dbmail',
    [switch]$SoloRevisar,
    [switch]$Reemplazar,
    [string]$CorreoPrueba,
    # Perfil de correo del SQL Agent en el destino; por defecto el mismo que tiene el origen.
    [string]$PerfilAgente,
    [securestring]$PasswordSmtp,
    [pscredential]$Credencial
)

$ErrorActionPreference = 'Stop'

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null
$log = Join-Path $Carpeta ("dbmail_{0}_{1}.log" -f ($Destino -replace '[\\/:*?"<>|,]', '_'), $stamp)
Start-Transcript -Path $log | Out-Null

$script:Atencion = New-Object System.Collections.Generic.List[string]
$script:Errores  = New-Object System.Collections.Generic.List[string]
function Write-Atencion([string]$m) { $script:Atencion.Add($m); Write-Host "  ATENCION: $m" -ForegroundColor Yellow }
function Write-Error2([string]$m)   { $script:Errores.Add($m);  Write-Host "  ERROR: $m" -ForegroundColor Red }
function Write-Ok([string]$m)       { Write-Host "  $m" -ForegroundColor Green }
function V($x) { if ($x -is [DBNull]) { $null } else { $x } }

function Open-Sql([string]$server) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $server
    $b['Initial Catalog'] = 'msdb'
    $b['Application Name'] = 'Migrar-DatabaseMail'
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

function Invoke-Sql($conn, [string]$sql, [hashtable]$p = @{}) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = 300
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

function Get-Mensaje($err) {
    $ex = $err.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    $ex.Message
}

$qAgente = @"
DECLARE @t TABLE (Value NVARCHAR(200), Data NVARCHAR(400));
INSERT @t EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'UseDatabaseMail';
INSERT @t EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile';
SELECT Value, Data FROM @t;
"@
function Get-AgenteMail($conn) {
    $r = @{ UseDatabaseMail = $null; DatabaseMailProfile = $null }
    try { foreach ($f in @(Invoke-Sql $conn $qAgente)) { $r[[string]$f.Value] = V $f.Data } } catch { }
    $r
}

$qCuentas = @"
SELECT a.account_id, a.name, a.description, a.email_address, a.display_name, a.replyto_address,
       s.servername, s.servertype, s.port, s.username, s.use_default_credentials, s.enable_ssl, s.timeout
FROM msdb.dbo.sysmail_account a
JOIN msdb.dbo.sysmail_server s ON s.account_id = a.account_id
ORDER BY a.name;
"@
$qPerfiles = "SELECT profile_id, name, description FROM msdb.dbo.sysmail_profile ORDER BY name;"
$qPerfilCuenta = @"
SELECT p.name AS perfil, a.name AS cuenta, pa.sequence_number
FROM msdb.dbo.sysmail_profileaccount pa
JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pa.profile_id
JOIN msdb.dbo.sysmail_account a ON a.account_id = pa.account_id
ORDER BY p.name, pa.sequence_number;
"@
$qPrincipal = @"
SELECT p.name AS perfil,
       CASE WHEN pp.principal_sid = 0x00 THEN N'public' ELSE dp.name END AS principal,
       pp.is_default
FROM msdb.dbo.sysmail_principalprofile pp
JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pp.profile_id
LEFT JOIN msdb.sys.database_principals dp ON dp.sid = pp.principal_sid
ORDER BY p.name;
"@
$qConfig = "SELECT paramname, paramvalue FROM msdb.dbo.sysmail_configuration ORDER BY paramname;"
$qXps = "SELECT CONVERT(INT, value_in_use) AS v FROM sys.configurations WHERE name = N'Database Mail XPs';"

# ---------------------------------------------------------------- conexion
Write-Host "Origen : $Origen" -ForegroundColor Cyan
Write-Host "Destino: $Destino" -ForegroundColor Cyan
if ($SoloRevisar) { Write-Host "MODO SOLO REVISION: no se escribe nada en $Destino" -ForegroundColor Magenta }

try {
    $src = Open-Sql $Origen
    $dst = Open-Sql $Destino
} catch {
    Write-Host "ERROR de conexion: $(Get-Mensaje $_)" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
$qInfo = "SELECT @@SERVERNAME AS n, IS_SRVROLEMEMBER('sysadmin') AS sa"
$infoSrc = @(Invoke-Sql $src $qInfo)[0]
$infoDst = @(Invoke-Sql $dst $qInfo)[0]
Write-Host ("  {0} = {1}" -f $Origen, $infoSrc.n)
Write-Host ("  {0} = {1}" -f $Destino, $infoDst.n)
if ($infoSrc.sa -ne 1 -or $infoDst.sa -ne 1) {
    Write-Host "ERROR: se requiere sysadmin en ambos servidores." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# ---------------------------------------------------------------- origen
$cuentas   = @(Invoke-Sql $src $qCuentas)
$perfiles  = @(Invoke-Sql $src $qPerfiles)
$enlaces   = @(Invoke-Sql $src $qPerfilCuenta)
$publicos  = @(Invoke-Sql $src $qPrincipal)
$config    = @(Invoke-Sql $src $qConfig)
$agenteSrc = Get-AgenteMail $src

if ($cuentas.Count -eq 0) {
    Write-Host "No hay cuentas de Database Mail en $Origen." -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    exit 1
}

Write-Host ""
Write-Host "=== Configuracion en $Origen" -ForegroundColor Cyan
foreach ($c in $cuentas) {
    $auth = 'Anonima'
    if ($c.use_default_credentials -eq $true) { $auth = 'Windows (cuenta del servicio)' }
    elseif (V $c.username) { $auth = "Basica ($($c.username))" }
    Write-Host ("  Cuenta : {0} <{1}> {2}:{3} SSL={4} Auth={5}" -f $c.name, $c.email_address, $c.servername, $c.port, $c.enable_ssl, $auth)
}
foreach ($p in $perfiles) {
    $lst = ($enlaces | Where-Object { $_.perfil -eq $p.name } | ForEach-Object { "$($_.sequence_number):$($_.cuenta)" }) -join ', '
    Write-Host ("  Perfil : {0} -> {1}" -f $p.name, $lst)
}
foreach ($pp in $publicos) {
    Write-Host ("  Acceso : perfil {0} para {1} (por defecto={2})" -f $pp.perfil, (V $pp.principal), $pp.is_default)
}
Write-Host ("  Agente : UseDatabaseMail={0} Perfil={1}" -f $agenteSrc.UseDatabaseMail, $agenteSrc.DatabaseMailProfile)

# ---------------------------------------------------------------- destino actual
$cuentasDst  = @(Invoke-Sql $dst $qCuentas)
$perfilesDst = @(Invoke-Sql $dst $qPerfiles)

if ($SoloRevisar) {
    Write-Host ""
    Write-Host "=== Que se haria en $Destino" -ForegroundColor Cyan
    if (@(Invoke-Sql $dst $qXps)[0].v -ne 1) { Write-Host "  Activar 'Database Mail XPs'" }
    foreach ($c in $cuentas) {
        $accion = 'CREAR'
        if (@($cuentasDst | Where-Object { $_.name -eq $c.name }).Count -gt 0) { $accion = 'existe (se omite; use -Reemplazar para actualizarla)'; if ($Reemplazar) { $accion = 'ACTUALIZAR' } }
        Write-Host "  Cuenta $($c.name): $accion"
    }
    foreach ($p in $perfiles) {
        $accion = 'CREAR'; if (@($perfilesDst | Where-Object { $_.name -eq $p.name }).Count -gt 0) { $accion = 'existe (se completan sus cuentas)' }
        Write-Host "  Perfil $($p.name): $accion"
    }
    $src.Close(); $dst.Close()
    Stop-Transcript | Out-Null
    exit 0
}

Write-Host ""
Write-Host "=== Aplicando en $Destino" -ForegroundColor Cyan

# --- Database Mail XPs
if (@(Invoke-Sql $dst $qXps)[0].v -ne 1) {
    try {
        Invoke-Sql $dst @"
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1; RECONFIGURE;
"@ | Out-Null
        Write-Ok "Database Mail XPs activado"
    } catch { Write-Error2 "No se pudo activar Database Mail XPs: $(Get-Mensaje $_)" }
}

# --- cuentas
$claves = @{}
foreach ($c in $cuentas) {
    $nombre = [string]$c.name
    $existe = @($cuentasDst | Where-Object { $_.name -eq $nombre })
    if ($existe.Count -gt 0 -and -not $Reemplazar) {
        Write-Atencion "La cuenta '$nombre' ya existe en $Destino; se deja como esta (use -Reemplazar para actualizarla)."
        continue
    }
    $usuario = [string](V $c.username)
    $password = $null
    if ($c.use_default_credentials -ne $true -and $usuario) {
        if ($PasswordSmtp) {
            $password = (New-Object System.Net.NetworkCredential('', $PasswordSmtp)).Password
        } elseif ($claves.ContainsKey($usuario)) {
            $password = $claves[$usuario]
        } else {
            $ss = Read-Host -AsSecureString "  Contrasena SMTP de '$usuario' (cuenta '$nombre')"
            $password = (New-Object System.Net.NetworkCredential('', $ss)).Password
            $claves[$usuario] = $password
        }
        if (-not $password) { Write-Atencion "No se ingreso contrasena para '$usuario'; la cuenta '$nombre' quedara sin contrasena." }
    }
    $prm = @{ name = $nombre; email = [string]$c.email_address; display = (V $c.display_name); reply = (V $c.replyto_address)
              descr = (V $c.description); server = [string]$c.servername; stype = [string]$c.servertype; port = $c.port
              user = (V $c.username); pwd = $password; udc = $c.use_default_credentials; ssl = $c.enable_ssl }
    try {
        if ($existe.Count -gt 0) {
            $prm['id'] = $existe[0].account_id
            $prm['timeout'] = (V $c.timeout)
            Invoke-Sql $dst @"
EXEC msdb.dbo.sysmail_update_account_sp @account_id = @id, @account_name = @name, @email_address = @email,
     @display_name = @display, @replyto_address = @reply, @description = @descr, @mailserver_name = @server,
     @mailserver_type = @stype, @port = @port, @username = @user, @password = @pwd,
     @use_default_credentials = @udc, @enable_ssl = @ssl, @timeout = @timeout;
"@ $prm | Out-Null
            Write-Ok "Cuenta actualizada: $nombre <$($c.email_address)> $($c.servername):$($c.port)"
        } else {
            Invoke-Sql $dst @"
EXEC msdb.dbo.sysmail_add_account_sp @account_name = @name, @email_address = @email, @display_name = @display,
     @replyto_address = @reply, @description = @descr, @mailserver_name = @server, @mailserver_type = @stype,
     @port = @port, @username = @user, @password = @pwd, @use_default_credentials = @udc, @enable_ssl = @ssl;
"@ $prm | Out-Null
            Write-Ok "Cuenta creada: $nombre <$($c.email_address)> $($c.servername):$($c.port)"
        }
    } catch { Write-Error2 "Cuenta '$nombre': $(Get-Mensaje $_)" }
}

# --- perfiles
foreach ($p in $perfiles) {
    $nombre = [string]$p.name
    try {
        if (@($perfilesDst | Where-Object { $_.name -eq $nombre }).Count -eq 0) {
            Invoke-Sql $dst "EXEC msdb.dbo.sysmail_add_profile_sp @profile_name = @n, @description = @d;" @{ n = $nombre; d = (V $p.description) } | Out-Null
            Write-Ok "Perfil creado: $nombre"
        } elseif ($Reemplazar) {
            Invoke-Sql $dst "EXEC msdb.dbo.sysmail_update_profile_sp @profile_name = @n, @description = @d;" @{ n = $nombre; d = (V $p.description) } | Out-Null
        }
    } catch { Write-Error2 "Perfil '$nombre': $(Get-Mensaje $_)" }
}

# --- cuentas de cada perfil
foreach ($e in $enlaces) {
    try {
        $actual = @(Invoke-Sql $dst @"
SELECT pa.sequence_number FROM msdb.dbo.sysmail_profileaccount pa
JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pa.profile_id
JOIN msdb.dbo.sysmail_account a ON a.account_id = pa.account_id
WHERE p.name = @p AND a.name = @a;
"@ @{ p = [string]$e.perfil; a = [string]$e.cuenta })
        if ($actual.Count -eq 0) {
            Invoke-Sql $dst "EXEC msdb.dbo.sysmail_add_profileaccount_sp @profile_name = @p, @account_name = @a, @sequence_number = @s;" @{ p = [string]$e.perfil; a = [string]$e.cuenta; s = $e.sequence_number } | Out-Null
            Write-Ok "Perfil $($e.perfil) <- cuenta $($e.cuenta) (orden $($e.sequence_number))"
        } elseif ($actual[0].sequence_number -ne $e.sequence_number) {
            Invoke-Sql $dst "EXEC msdb.dbo.sysmail_update_profileaccount_sp @profile_name = @p, @account_name = @a, @sequence_number = @s;" @{ p = [string]$e.perfil; a = [string]$e.cuenta; s = $e.sequence_number } | Out-Null
            Write-Ok "Perfil $($e.perfil): orden de la cuenta $($e.cuenta) -> $($e.sequence_number)"
        }
    } catch { Write-Error2 "Perfil '$($e.perfil)' / cuenta '$($e.cuenta)': $(Get-Mensaje $_)" }
}

# --- acceso a perfiles (public / por defecto)
foreach ($pp in $publicos) {
    $principal = V $pp.principal
    if (-not $principal) { Write-Atencion "El perfil '$($pp.perfil)' esta asignado a un usuario de msdb que ya no existe en $Origen; se omite."; continue }
    try {
        $actual = @(Invoke-Sql $dst @"
SELECT pp.is_default FROM msdb.dbo.sysmail_principalprofile pp
JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pp.profile_id
LEFT JOIN msdb.sys.database_principals dp ON dp.sid = pp.principal_sid
WHERE p.name = @p AND (CASE WHEN pp.principal_sid = 0x00 THEN N'public' ELSE dp.name END) = @u;
"@ @{ p = [string]$pp.perfil; u = [string]$principal })
        if ($principal -ne 'public' -and @(Invoke-Sql $dst "SELECT 1 AS x FROM msdb.sys.database_principals WHERE name = @u" @{ u = [string]$principal }).Count -eq 0) {
            Write-Atencion "El usuario '$principal' no existe en msdb de $Destino; no se le asigna el perfil '$($pp.perfil)' (migre primero los usuarios)."
            continue
        }
        if ($actual.Count -eq 0) {
            Invoke-Sql $dst "EXEC msdb.dbo.sysmail_add_principalprofile_sp @principal_name = @u, @profile_name = @p, @is_default = @d;" @{ u = [string]$principal; p = [string]$pp.perfil; d = $pp.is_default } | Out-Null
            Write-Ok "Perfil $($pp.perfil) asignado a $principal (por defecto=$($pp.is_default))"
        } elseif ($actual[0].is_default -ne $pp.is_default) {
            Invoke-Sql $dst "EXEC msdb.dbo.sysmail_update_principalprofile_sp @principal_name = @u, @profile_name = @p, @is_default = @d;" @{ u = [string]$principal; p = [string]$pp.perfil; d = $pp.is_default } | Out-Null
            Write-Ok "Perfil $($pp.perfil) para ${principal}: por defecto=$($pp.is_default)"
        }
    } catch { Write-Error2 "Acceso al perfil '$($pp.perfil)' para '$principal': $(Get-Mensaje $_)" }
}

# --- parametros del sistema
$configDst = @{}
foreach ($r in @(Invoke-Sql $dst $qConfig)) { $configDst[[string]$r.paramname] = [string](V $r.paramvalue) }
foreach ($r in $config) {
    $n = [string]$r.paramname; $v = [string](V $r.paramvalue)
    if ($configDst[$n] -ne $v) {
        try {
            Invoke-Sql $dst "EXEC msdb.dbo.sysmail_configure_sp @parameter_name = @n, @parameter_value = @v;" @{ n = $n; v = $v } | Out-Null
            Write-Ok "Parametro $n = $v (antes: $($configDst[$n]))"
        } catch { Write-Error2 "Parametro '$n': $(Get-Mensaje $_)" }
    }
}

# --- SQL Server Agent (Alert System)
$agenteDst = Get-AgenteMail $dst
$perfilDelAgente = $agenteSrc.DatabaseMailProfile
if ($PerfilAgente) { $perfilDelAgente = $PerfilAgente }
if ($perfilDelAgente) {
    if ($agenteDst.DatabaseMailProfile -ne $perfilDelAgente -or [string]$agenteDst.UseDatabaseMail -ne '1') {
        try {
            Invoke-Sql $dst "EXEC msdb.dbo.sp_set_sqlagent_properties @use_databasemail = 1, @databasemail_profile = @p;" @{ p = [string]$perfilDelAgente } | Out-Null
            Write-Ok "SQL Agent: perfil de correo = $perfilDelAgente"
            Write-Atencion "Reinicie el servicio SQL Server Agent en $Destino para que tome el perfil de correo."
        } catch {
            Write-Atencion "No se pudo asignar el perfil '$perfilDelAgente' al SQL Agent ($(Get-Mensaje $_)). Hagalo a mano en ${Destino}: SQL Server Agent > Properties > Alert System > Enable mail profile = $perfilDelAgente, y reinicie el Agent."
        }
    }
} else {
    Write-Atencion "No se pudo leer el perfil de correo del SQL Agent en $Origen; indiquelo con -PerfilAgente o configurelo en ${Destino}: SQL Server Agent > Properties > Alert System."
}

# --- correo de prueba
if ($CorreoPrueba) {
    $perfilPrueba = $perfilDelAgente
    if (-not $perfilPrueba -and $perfiles.Count -gt 0) { $perfilPrueba = [string]$perfiles[0].name }
    Write-Host ""
    Write-Host "=== Correo de prueba a $CorreoPrueba (perfil $perfilPrueba)" -ForegroundColor Cyan
    try {
        $id = @(Invoke-Sql $dst @"
DECLARE @id INT;
EXEC msdb.dbo.sp_send_dbmail @profile_name = @p, @recipients = @r,
     @subject = @s, @body = @b, @mailitem_id = @id OUTPUT;
SELECT @id AS id;
"@ @{ p = $perfilPrueba; r = $CorreoPrueba; s = "Prueba Database Mail desde $($infoDst.n)"; b = "Correo de prueba enviado por Migrar-DatabaseMail.ps1 el $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')." })[0].id
        $estado = 'unsent'
        for ($i = 0; $i -lt 12 -and $estado -eq 'unsent'; $i++) {
            Start-Sleep -Seconds 5
            $estado = [string]@(Invoke-Sql $dst "SELECT sent_status FROM msdb.dbo.sysmail_allitems WHERE mailitem_id = @id" @{ id = $id })[0].sent_status
        }
        if ($estado -eq 'sent') { Write-Ok "Correo enviado correctamente (mailitem_id $id)." }
        else {
            Write-Error2 "El correo de prueba quedo en estado '$estado' (mailitem_id $id)."
            Invoke-Sql $dst "SELECT TOP 3 log_date, description FROM msdb.dbo.sysmail_event_log WHERE mailitem_id = @id ORDER BY log_id DESC" @{ id = $id } |
                ForEach-Object {
                    $d = [string]$_.description
                    $m = [regex]::Match($d, '(?m)^Message: (.+)$')
                    if ($m.Success) { $d = $m.Groups[1].Value } else { $d = ($d -split "`r?`n")[0] }
                    Write-Host "    $($_.log_date): $d" -ForegroundColor Red
                }
        }
    } catch { Write-Error2 "Correo de prueba: $(Get-Mensaje $_)" }
}

# ---------------------------------------------------------------- resumen
Write-Host ""
Write-Host "===== RESUMEN =====" -ForegroundColor Cyan
Write-Host "Cuentas en ${Destino}:"
Invoke-Sql $dst $qCuentas | Select-Object name, email_address, servername, port, enable_ssl, username |
    Format-Table -AutoSize | Out-String -Width 250 | Write-Host
Write-Host "Perfiles en ${Destino}:"
Invoke-Sql $dst $qPerfilCuenta | Select-Object perfil, cuenta, sequence_number | Format-Table -AutoSize | Out-String | Write-Host

Write-Host ("Errores  : {0}" -f $script:Errores.Count)  -ForegroundColor $(if ($script:Errores.Count)  { 'Red' }    else { 'Green' })
Write-Host ("ATENCION : {0}" -f $script:Atencion.Count) -ForegroundColor $(if ($script:Atencion.Count) { 'Yellow' } else { 'Green' })
$script:Atencion | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
$script:Errores  | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
Write-Host ""
Write-Host "Log: $log"

$src.Close(); $dst.Close()
Stop-Transcript | Out-Null
if ($script:Errores.Count -gt 0) { exit 1 } else { exit 0 }
