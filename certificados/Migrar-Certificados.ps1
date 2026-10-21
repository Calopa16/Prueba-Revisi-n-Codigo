<#
.SYNOPSIS
    Migra certificados de master (con su clave privada) de un servidor SQL Server a otro.
    Ejemplo: el certificado que usan los planes de mantenimiento para cifrar backups o TDE.

.DESCRIPTION
    - Lee los certificados de usuario de master en el origen (no los ##MS_...##).
    - Los copia al destino con CERTENCODED / CERTPRIVATEKEY + CREATE CERTIFICATE FROM BINARY,
      sin copiar archivos entre servidores. La clave privada viaja cifrada con una clave
      temporal aleatoria que solo existe en memoria durante la ejecucion.
    - Crea la Database Master Key de master en el destino si no existe (pide la contrasena).
    - Verifica que el thumbprint en el destino sea identico al del origen.
    - Opcional: guarda un respaldo .cer/.pvk en tu PC (-PasswordRespaldo).

.EXAMPLE
    .\Migrar-Certificados.ps1 -Origen tanatos -Destino hermes -SoloRevisar
    .\Migrar-Certificados.ps1 -Origen tanatos -Destino hermes
    .\Migrar-Certificados.ps1 -Origen tanatos -Destino hermes -Certificados CertiBDProduction
    .\Migrar-Certificados.ps1 -Origen tanatos -Destino hermes -PasswordRespaldo (Read-Host -AsSecureString)
#>
param(
    [string]$Origen  = 'tanatos',
    [string]$Destino = 'hermes',
    # Por defecto todos los certificados de usuario de master. Opcional: nombres exactos o con *.
    [string[]]$Certificados = @('*'),
    [string]$Carpeta = 'C:\temp\sync_certificados',
    [switch]$SoloRevisar,
    [switch]$Reemplazar,
    [securestring]$PasswordMasterKey,
    [securestring]$PasswordCertificado,
    [securestring]$PasswordRespaldo,
    [pscredential]$Credencial
)

$ErrorActionPreference = 'Stop'

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null
$log = Join-Path $Carpeta ("certificados_{0}_{1}.log" -f ($Destino -replace '[\\/:*?"<>|,]', '_'), $stamp)
Start-Transcript -Path $log | Out-Null

$script:Atencion = New-Object System.Collections.Generic.List[string]
$script:Errores  = New-Object System.Collections.Generic.List[string]
function Write-Atencion([string]$m) { $script:Atencion.Add($m); Write-Host "  ATENCION: $m" -ForegroundColor Yellow }
function Write-Error2([string]$m)   { $script:Errores.Add($m);  Write-Host "  ERROR: $m" -ForegroundColor Red }
function Write-Ok([string]$m)       { Write-Host "  $m" -ForegroundColor Green }
function V($x) { if ($x -is [DBNull]) { $null } else { $x } }
function Get-Plano([securestring]$s) { (New-Object System.Net.NetworkCredential('', $s)).Password }
function Get-Hex([byte[]]$b) { if ($b) { '0x' + (($b | ForEach-Object { $_.ToString('X2') }) -join '') } else { '' } }

function Open-Sql([string]$server) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $server
    $b['Initial Catalog'] = 'master'
    $b['Application Name'] = 'Migrar-Certificados'
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

function New-ClaveTemporal {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    'Tmp#' + [Convert]::ToBase64String($bytes) + '9a'
}

function Test-Pedido([string]$n) {
    foreach ($p in $Certificados) {
        if ($p.Contains('*')) { if ($n -like $p) { return $true } }
        elseif ($n -eq $p.Trim()) { return $true }
    }
    $false
}

$qCerts = @"
SELECT c.certificate_id, c.name, c.subject, c.start_date, c.expiry_date, c.pvt_key_encryption_type AS pk_tipo,
       c.thumbprint
FROM master.sys.certificates c
WHERE c.name NOT LIKE N'##%'
ORDER BY c.name;
"@
$qUsoTde = @"
SELECT DB_NAME(k.database_id) AS bd, k.encryption_state_desc AS estado
FROM sys.dm_database_encryption_keys k
WHERE k.encryptor_thumbprint = @t AND k.database_id > 4;
"@
$qUsoBackup = @"
SELECT COUNT(*) AS n, MAX(backup_finish_date) AS ultimo
FROM msdb.dbo.backupset
WHERE encryptor_thumbprint = @t;
"@

# ---------------------------------------------------------------- conexion
Write-Host "Origen       : $Origen" -ForegroundColor Cyan
Write-Host "Destino      : $Destino" -ForegroundColor Cyan
Write-Host "Certificados : $($Certificados -join ' | ')" -ForegroundColor Cyan
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
$todos = @(Invoke-Sql $src $qCerts)
$certs = @($todos | Where-Object { Test-Pedido ([string]$_.name) })
foreach ($p in $Certificados) {
    if (-not $p.Contains('*') -and @($todos | Where-Object { $_.name -eq $p.Trim() }).Count -eq 0) {
        Write-Atencion "El certificado '$p' no existe en master de $Origen."
    }
}
if ($certs.Count -eq 0) {
    Write-Host "No hay certificados para migrar en master de $Origen." -ForegroundColor Yellow
    if ($todos.Count -gt 0) { Write-Host "Disponibles: $(($todos | ForEach-Object { $_.name }) -join ', ')" }
    Stop-Transcript | Out-Null
    exit 1
}

$dstCerts = @(Invoke-Sql $dst $qCerts)
$tieneMk = @(Invoke-Sql $dst "SELECT 1 AS x FROM master.sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##'").Count -gt 0

Write-Host ""
Write-Host "=== Certificados en $Origen" -ForegroundColor Cyan
foreach ($c in $certs) {
    $tp = Get-Hex ([byte[]]$c.thumbprint)
    Write-Host ("  {0}  (sujeto: {1}, vence: {2:yyyy-MM-dd}, clave privada: {3})" -f $c.name, $c.subject, $c.expiry_date, $c.pk_tipo)
    Write-Host "    thumbprint $tp" -ForegroundColor DarkGray
    foreach ($u in @(Invoke-Sql $src $qUsoTde @{ t = [byte[]]$c.thumbprint })) { Write-Host "    Usado por TDE en la base $($u.bd) ($($u.estado))" -ForegroundColor DarkGray }
    $ub = @(Invoke-Sql $src $qUsoBackup @{ t = [byte[]]$c.thumbprint })[0]
    if ($ub.n -gt 0) { Write-Host ("    Usado para cifrar {0} backup(s); ultimo: {1}" -f $ub.n, (V $ub.ultimo)) -ForegroundColor DarkGray }
    if ($c.expiry_date -lt (Get-Date)) { Write-Atencion "El certificado '$($c.name)' esta VENCIDO ($($c.expiry_date)). Sigue sirviendo para TDE y backups, pero revise su renovacion." }
    if ([string]$c.pk_tipo -eq 'NA') { Write-Atencion "El certificado '$($c.name)' no tiene clave privada en $Origen; se copiara solo la parte publica (no sirve para cifrar backups ni TDE)." }
}

if ($SoloRevisar) {
    Write-Host ""
    Write-Host "=== Que se haria en $Destino" -ForegroundColor Cyan
    if (-not $tieneMk) { Write-Host "  Crear la Database Master Key de master (se pedira contrasena)" }
    foreach ($c in $certs) {
        $e = @($dstCerts | Where-Object { $_.name -eq $c.name })
        $accion = 'CREAR'
        if ($e.Count -gt 0) {
            if ((Get-Hex ([byte[]]$e[0].thumbprint)) -eq (Get-Hex ([byte[]]$c.thumbprint))) { $accion = 'ya existe (mismo thumbprint), nada que hacer' }
            elseif ($Reemplazar) { $accion = 'REEMPLAZAR (thumbprint distinto)' }
            else { $accion = 'existe con OTRO thumbprint (use -Reemplazar)' }
        }
        Write-Host "  $($c.name): $accion"
    }
    $src.Close(); $dst.Close()
    Stop-Transcript | Out-Null
    exit 0
}

# ---------------------------------------------------------------- destino
Write-Host ""
Write-Host "=== Aplicando en $Destino" -ForegroundColor Cyan

if (-not $tieneMk) {
    $pwMk = $PasswordMasterKey
    if (-not $pwMk) {
        Write-Host "  $Destino no tiene Database Master Key en master; se creara una." -ForegroundColor Yellow
        $pwMk = Read-Host -AsSecureString "  Contrasena para la Master Key de master en $Destino (guardela en lugar seguro)"
    }
    try {
        Invoke-Sql $dst @"
DECLARE @sql NVARCHAR(MAX) = N'CREATE MASTER KEY ENCRYPTION BY PASSWORD = N''' + REPLACE(@p, N'''', N'''''') + N''';';
EXEC (@sql);
"@ @{ p = (Get-Plano $pwMk) } | Out-Null
        Write-Ok "Database Master Key creada en master de $Destino"
        Write-Atencion "Respalde la Master Key de ${Destino}: BACKUP MASTER KEY TO FILE = '...' ENCRYPTION BY PASSWORD = '...'"
    } catch {
        Write-Error2 "No se pudo crear la Master Key: $(Get-Mensaje $_)"
        Stop-Transcript | Out-Null
        exit 1
    }
}

$pwCertPlano = $null
if ($PasswordCertificado) { $pwCertPlano = Get-Plano $PasswordCertificado }

foreach ($c in $certs) {
    $nombre = [string]$c.name
    $tpSrc  = Get-Hex ([byte[]]$c.thumbprint)
    $e = @($dstCerts | Where-Object { $_.name -eq $nombre })
    if ($e.Count -gt 0) {
        if ((Get-Hex ([byte[]]$e[0].thumbprint)) -eq $tpSrc) { Write-Ok "$nombre ya existe en $Destino con el mismo thumbprint; nada que hacer."; continue }
        if (-not $Reemplazar) { Write-Atencion "$nombre existe en $Destino con OTRO thumbprint; no se toca (use -Reemplazar)."; continue }
    }

    $temporal = New-ClaveTemporal
    $tipo = [string]$c.pk_tipo
    if ($tipo -eq 'PW' -and -not $pwCertPlano) {
        $pwCertPlano = Get-Plano (Read-Host -AsSecureString "  Contrasena de la clave privada de '$nombre' en $Origen")
    }
    try {
        $datos = @(Invoke-Sql $src @"
SELECT CERTENCODED(@id) AS publico,
       CASE @tipo WHEN 'NA' THEN NULL
                  WHEN 'PW' THEN CERTPRIVATEKEY(@id, @tmp, @dec)
                  ELSE CERTPRIVATEKEY(@id, @tmp) END AS privado;
"@ @{ id = $c.certificate_id; tipo = $tipo; tmp = $temporal; dec = $pwCertPlano })[0]
    } catch { Write-Error2 "${nombre}: no se pudo leer del origen: $(Get-Mensaje $_)"; continue }

    $publico = [byte[]](V $datos.publico)
    $privado = [byte[]](V $datos.privado)
    if ($tipo -ne 'NA' -and -not $privado) { Write-Error2 "${nombre}: no se pudo exportar la clave privada (revise la contrasena del certificado)."; continue }

    try {
        if ($e.Count -gt 0) {
            Invoke-Sql $dst "DECLARE @s NVARCHAR(400) = N'DROP CERTIFICATE ' + QUOTENAME(@n); EXEC (@s);" @{ n = $nombre } | Out-Null
            Write-Host "  $nombre anterior eliminado en $Destino" -ForegroundColor DarkYellow
        }
        Invoke-Sql $dst @"
DECLARE @sql NVARCHAR(MAX) = N'CREATE CERTIFICATE ' + QUOTENAME(@n) + N' FROM BINARY = ' + CONVERT(NVARCHAR(MAX), @pub, 1)
    + CASE WHEN @priv IS NULL THEN N''
           ELSE N' WITH PRIVATE KEY (BINARY = ' + CONVERT(NVARCHAR(MAX), @priv, 1)
              + N', DECRYPTION BY PASSWORD = N''' + REPLACE(@tmp, N'''', N'''''') + N''')' END + N';';
EXEC (@sql);
"@ @{ n = $nombre; pub = $publico; priv = $privado; tmp = $temporal } | Out-Null
    } catch { Write-Error2 "${nombre}: no se pudo crear en ${Destino}: $(Get-Mensaje $_)"; continue }

    $nuevo = @(Invoke-Sql $dst "SELECT thumbprint, pvt_key_encryption_type AS pk_tipo FROM master.sys.certificates WHERE name = @n" @{ n = $nombre })
    if ($nuevo.Count -gt 0 -and (Get-Hex ([byte[]]$nuevo[0].thumbprint)) -eq $tpSrc) {
        Write-Ok "$nombre creado en $Destino (thumbprint identico, clave privada: $($nuevo[0].pk_tipo))"
    } else {
        Write-Error2 "${nombre}: el thumbprint en $Destino no coincide con el del origen."
    }

    if ($PasswordRespaldo -and $tipo -ne 'NA') {
        try {
            $r = @(Invoke-Sql $src @"
SELECT CASE @tipo WHEN 'PW' THEN CERTPRIVATEKEY(@id, @pr, @dec) ELSE CERTPRIVATEKEY(@id, @pr) END AS privado;
"@ @{ id = $c.certificate_id; tipo = $tipo; pr = (Get-Plano $PasswordRespaldo); dec = $pwCertPlano })[0]
            $base = Join-Path $Carpeta ($nombre -replace '[\\/:*?"<>|]', '_')
            [IO.File]::WriteAllBytes("$base.cer", $publico)
            [IO.File]::WriteAllBytes("$base.pvk", [byte[]]$r.privado)
            Write-Ok "Respaldo guardado: $base.cer / $base.pvk (clave privada cifrada con -PasswordRespaldo)"
        } catch { Write-Atencion "${nombre}: no se pudo guardar el respaldo: $(Get-Mensaje $_)" }
    }
}

# ---------------------------------------------------------------- resumen
Write-Host ""
Write-Host "===== RESUMEN =====" -ForegroundColor Cyan
$filas = foreach ($c in $certs) {
    $d = @(Invoke-Sql $dst "SELECT thumbprint, pvt_key_encryption_type AS pk_tipo FROM master.sys.certificates WHERE name = @n" @{ n = [string]$c.name })
    $estado = 'NO EXISTE'
    if ($d.Count -gt 0) {
        if ((Get-Hex ([byte[]]$d[0].thumbprint)) -eq (Get-Hex ([byte[]]$c.thumbprint))) { $estado = 'OK (mismo thumbprint)' } else { $estado = 'DISTINTO' }
    }
    $pk = ''; if ($d.Count -gt 0) { $pk = $d[0].pk_tipo }
    [pscustomobject]@{ Certificado = $c.name; Vence = ('{0:yyyy-MM-dd}' -f $c.expiry_date); EnDestino = $estado; ClavePrivada = $pk }
}
$filas | Format-Table -AutoSize | Out-String | Write-Host

Write-Host ("Errores  : {0}" -f $script:Errores.Count)  -ForegroundColor $(if ($script:Errores.Count)  { 'Red' }    else { 'Green' })
Write-Host ("ATENCION : {0}" -f $script:Atencion.Count) -ForegroundColor $(if ($script:Atencion.Count) { 'Yellow' } else { 'Green' })
$script:Atencion | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
$script:Errores  | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
Write-Host ""
Write-Host "Log: $log"

$src.Close(); $dst.Close()
Stop-Transcript | Out-Null
if ($script:Errores.Count -gt 0) { exit 1 } else { exit 0 }
