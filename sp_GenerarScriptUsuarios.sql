USE [master];
GO

IF OBJECT_ID('dbo.sp_GenerarScriptUsuarios', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_GenerarScriptUsuarios;
GO

/*
=============================================================================
  sp_GenerarScriptUsuarios
  Genera un script T-SQL idempotente que replica, en otro servidor SQL Server
  (2012-2022), todos los logins, usuarios de base de datos, membresías de
  roles y permisos explícitos del servidor origen.

  Parámetros
  ----------
  @IncluirSQLLogins     BIT     = 1
      Incluye logins de tipo SQL Server (tipo 'S').

  @IncluirWindowsLogins BIT     = 1
      Incluye logins de Windows: usuario ('U') y grupo ('G').

  @SoloBaseDatos        sysname = NULL
      Restringe la sección 4 a una base de datos concreta.
      NULL = todas las BBDDs de usuario que estén ONLINE y no sean read-only.

  Salida
  ------
  Devuelve el script línea a línea (una fila = una línea).
  En SSMS use Ctrl+T (Results to Text) antes de ejecutar para
  copiar/pegar el bloque completo sin truncado de celda.

  Comportamiento
  --------------
  - IDEMPOTENTE: el script generado puede ejecutarse varias veces sin error.
  - Logins SQL: PASSWORD HASHED + SID original para que los usuarios de BD
    restaurados desde backup queden vinculados sin sp_change_users_login.
  - Logins deshabilitados: se reconstruyen deshabilitados en destino.
  - ALTER USER WITH LOGIN reemplaza a sp_change_users_login (deprecado).
  - Usuarios huérfanos (SID sin login en el servidor):
      * Si existe un login con el MISMO NOMBRE → ALTER USER WITH LOGIN
        para reparar el SID mismatch post-restore.
      * Sin login relacionado → comentario de advertencia para el DBA.
  - Permisos REVOKE implícitos (state = 'R') no se scriptan.
  - Filtros con COLLATE DATABASE_DEFAULT para evitar conflictos de collation
    entre la BD de usuario y los catálogos de master.

  Compatibilidad
  --------------
  SQL Server 2012 – 2022 (todas las ediciones).
=============================================================================
*/
CREATE PROCEDURE dbo.sp_GenerarScriptUsuarios
    @IncluirSQLLogins     BIT     = 1,
    @IncluirWindowsLogins BIT     = 1,
    @SoloBaseDatos        sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#ScriptOutput') IS NOT NULL
        DROP TABLE #ScriptOutput;

    CREATE TABLE #ScriptOutput (
        Id   INT IDENTITY(1,1) PRIMARY KEY,
        Line NVARCHAR(MAX) NOT NULL
    );

    BEGIN TRY

    /* ====================================================================
       ENCABEZADO DEL SCRIPT GENERADO
       ==================================================================== */
    INSERT INTO #ScriptOutput (Line) VALUES
        (N'/*=================================================================='),
        (N'  SCRIPT DE SINCRONIZACIÓN DE LOGINS, USUARIOS Y PERMISOS'),
        (N'  Servidor Origen : ' + @@SERVERNAME),
        (N'  Fecha Generación: ' + CONVERT(VARCHAR(20), GETDATE(), 120)),
        (N'  Compatibilidad  : SQL Server 2012 – 2022'),
        (N'  Idempotente     : Sí – apto para servidor de contingencia'),
        (N''),
        (N'  ERRORES ESPERADOS EN DESTINO'),
        (N'  ----------------------------'),
        (N'  Msg 3906 (read-only): La BD de destino está en modo read-only'),
        (N'           (p. ej. réplica AlwaysOn o DATABASE SET READ_ONLY).'),
        (N'           Comente o elimine la sección de esa BD en el script.'),
        (N'  Msg 911  (no existe): La BD no existe en el servidor de destino.'),
        (N'           Créela primero o elimine su sección del script.'),
        (N'  RAISERROR sev 10: Avisos informativos (huérfanos, etc.). No fatales.'),
        (N'==================================================================*/'),
        (N''),
        (N'USE [master];'),
        (N'GO'),
        (N'');

    /* ====================================================================
       1. LOGINS
          SQL Server (tipo S), Windows usuario (U) y Windows grupo (G).
          Los logins SQL incluyen PASSWORD HASHED + SID original para que
          los database users restaurados desde backup queden vinculados
          automáticamente sin necesidad de sp_change_users_login.
       ==================================================================== */
    INSERT INTO #ScriptOutput (Line) VALUES
        (N'/* ================================================================== */'),
        (N'/* 1. LOGINS                                                          */'),
        (N'/* ================================================================== */'),
        (N'');

    INSERT INTO #ScriptOutput (Line)
    SELECT
        N'/* --- LOGIN: ' + sp.name + N' (' + sp.type_desc COLLATE DATABASE_DEFAULT + N') --- */'
        + CHAR(13)+CHAR(10)

        /* ---------- CREATE (si el login no existe en destino) ---------- */
        + N'IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '
            + QUOTENAME(sp.name, '''') + N')'
        + CHAR(13)+CHAR(10)
        + N'BEGIN' + CHAR(13)+CHAR(10)
        + CASE sp.type
            WHEN 'S' THEN
                N'    CREATE LOGIN ' + QUOTENAME(sp.name)
                + N' WITH PASSWORD = '    + CONVERT(NVARCHAR(MAX), sl.password_hash, 1) + N' HASHED'
                + N', SID = '             + CONVERT(NVARCHAR(MAX), sp.sid, 1)
                + N', DEFAULT_DATABASE = '+ QUOTENAME(ISNULL(sp.default_database_name,  N'master'))
                + N', DEFAULT_LANGUAGE = '+ QUOTENAME(ISNULL(sp.default_language_name,  N'us_english'))
                + N', CHECK_POLICY = '    + CASE WHEN sl.is_policy_checked    = 1 THEN N'ON' ELSE N'OFF' END
                + N', CHECK_EXPIRATION = '+ CASE WHEN sl.is_expiration_checked = 1 THEN N'ON' ELSE N'OFF' END
                + N';'
            WHEN 'U' THEN
                N'    CREATE LOGIN ' + QUOTENAME(sp.name) + N' FROM WINDOWS'
                + N' WITH DEFAULT_DATABASE = '+ QUOTENAME(ISNULL(sp.default_database_name, N'master'))
                + N', DEFAULT_LANGUAGE = '    + QUOTENAME(ISNULL(sp.default_language_name, N'us_english'))
                + N';'
            WHEN 'G' THEN
                N'    CREATE LOGIN ' + QUOTENAME(sp.name) + N' FROM WINDOWS'
                + N' WITH DEFAULT_DATABASE = '+ QUOTENAME(ISNULL(sp.default_database_name, N'master'))
                + N', DEFAULT_LANGUAGE = '    + QUOTENAME(ISNULL(sp.default_language_name, N'us_english'))
                + N';'
          END
        + CHAR(13)+CHAR(10)
        + N'END'   + CHAR(13)+CHAR(10)

        /* ---------- ALTER LOGIN (si el login ya existe en destino) ----------
         * No se modifica la contraseña para no romper sesiones activas.
         * Sí se actualizan las demás propiedades para mantener la paridad. */
        + N'ELSE' + CHAR(13)+CHAR(10)
        + N'BEGIN' + CHAR(13)+CHAR(10)
        + N'    ALTER LOGIN ' + QUOTENAME(sp.name)
        + N' WITH DEFAULT_DATABASE = '+ QUOTENAME(ISNULL(sp.default_database_name,  N'master'))
        + N', DEFAULT_LANGUAGE = '    + QUOTENAME(ISNULL(sp.default_language_name,  N'us_english'))
        + CASE sp.type
            WHEN 'S' THEN
                N', CHECK_POLICY = '    + CASE WHEN sl.is_policy_checked    = 1 THEN N'ON' ELSE N'OFF' END
                + N', CHECK_EXPIRATION = '+ CASE WHEN sl.is_expiration_checked = 1 THEN N'ON' ELSE N'OFF' END
            ELSE N''
          END
        + N';' + CHAR(13)+CHAR(10)
        + N'END;' + CHAR(13)+CHAR(10)

        /* ---------- Estado del login ---------- */
        + CASE WHEN sp.is_disabled = 1
            THEN N'ALTER LOGIN ' + QUOTENAME(sp.name) + N' DISABLE;'
            ELSE N'ALTER LOGIN ' + QUOTENAME(sp.name) + N' ENABLE;'
          END
        + CHAR(13)+CHAR(10)
        + N'GO'

    FROM sys.server_principals sp
    LEFT JOIN sys.sql_logins sl ON sp.principal_id = sl.principal_id
    WHERE (
            (@IncluirSQLLogins     = 1 AND sp.type = 'S')
         OR (@IncluirWindowsLogins = 1 AND sp.type IN ('U', 'G'))
          )
      AND sp.name NOT LIKE '##%'
      AND sp.name NOT LIKE N'NT SERVICE\%'
      AND sp.name NOT LIKE N'NT AUTHORITY\%'
      AND sp.name <> N'sa'
    ORDER BY sp.type, sp.name;

    /* ====================================================================
       2. MEMBRESÍA EN ROLES DE SERVIDOR
          sysadmin, dbcreator, securityadmin, etc.
          IS_SRVROLEMEMBER: 1=miembro, 0=no miembro, NULL=error.
          Se usa = 0 (en lugar de <> 1) para no ejecutar ALTER cuando
          la función retorna NULL (rol o login inexistente en destino).
       ==================================================================== */
    INSERT INTO #ScriptOutput (Line) VALUES
        (N''),
        (N'/* ================================================================== */'),
        (N'/* 2. MEMBRESÍA EN ROLES DE SERVIDOR                                  */'),
        (N'/* ================================================================== */'),
        (N'');

    INSERT INTO #ScriptOutput (Line)
    SELECT
        N'/* ' + m.name + N' → ' + r.name + N' */' + CHAR(13)+CHAR(10)
        + N'IF IS_SRVROLEMEMBER(' + QUOTENAME(r.name, '''') + N', ' + QUOTENAME(m.name, '''') + N') = 0'
        + CHAR(13)+CHAR(10)
        + N'    ALTER SERVER ROLE ' + QUOTENAME(r.name) + N' ADD MEMBER ' + QUOTENAME(m.name) + N';'
        + CHAR(13)+CHAR(10)
        + N'GO'
    FROM sys.server_role_members rm
    INNER JOIN sys.server_principals r ON rm.role_principal_id  = r.principal_id
    INNER JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
    WHERE (
            (@IncluirSQLLogins     = 1 AND m.type = 'S')
         OR (@IncluirWindowsLogins = 1 AND m.type IN ('U', 'G'))
          )
      AND m.name NOT LIKE '##%'
      AND m.name NOT LIKE N'NT SERVICE\%'
      AND m.name NOT LIKE N'NT AUTHORITY\%'
      AND m.name <> N'sa'
    ORDER BY r.name, m.name;

    /* ====================================================================
       3. PERMISOS EXPLÍCITOS A NIVEL DE SERVIDOR
          GRANT / DENY sobre permisos de servidor (CONNECT SQL se excluye
          porque es implícito para todo login válido).
          Se usa state (char) en lugar de state_desc (varchar) para ser
          independiente del idioma de instalación del servidor.
          Estado R (REVOKE implícito) no se scriptea.
       ==================================================================== */
    INSERT INTO #ScriptOutput (Line) VALUES
        (N''),
        (N'/* ================================================================== */'),
        (N'/* 3. PERMISOS EXPLÍCITOS DE SERVIDOR                                 */'),
        (N'/* ================================================================== */'),
        (N'');

    INSERT INTO #ScriptOutput (Line)
    SELECT
        CASE spm.state
            WHEN 'W' THEN N'GRANT '  + spm.permission_name + N' TO ' + QUOTENAME(sp.name) + N' WITH GRANT OPTION;'
            WHEN 'G' THEN N'GRANT '  + spm.permission_name + N' TO ' + QUOTENAME(sp.name) + N';'
            WHEN 'D' THEN N'DENY '   + spm.permission_name + N' TO ' + QUOTENAME(sp.name) + N';'
        END
        + CHAR(13)+CHAR(10)
        + N'GO'
    FROM sys.server_permissions spm
    INNER JOIN sys.server_principals sp ON spm.grantee_principal_id = sp.principal_id
    WHERE (
            (@IncluirSQLLogins     = 1 AND sp.type = 'S')
         OR (@IncluirWindowsLogins = 1 AND sp.type IN ('U', 'G'))
          )
      AND sp.name NOT LIKE '##%'
      AND sp.name NOT LIKE N'NT SERVICE\%'
      AND sp.name NOT LIKE N'NT AUTHORITY\%'
      AND sp.name <> N'sa'
      AND spm.state IN ('G', 'D', 'W')
      AND spm.type  <> 'COSQ'
    ORDER BY sp.name, spm.permission_name;

    /* ====================================================================
       4. USUARIOS, ROLES Y PERMISOS POR BASE DE DATOS
       ==================================================================== */
    INSERT INTO #ScriptOutput (Line) VALUES
        (N''),
        (N'/* ================================================================== */'),
        (N'/* 4. USUARIOS, ROLES Y PERMISOS POR BASE DE DATOS                   */'),
        (N'/* ================================================================== */');

    DECLARE @DBName     sysname;
    DECLARE @SQLDynamic NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FORWARD_ONLY READ_ONLY FOR
    SELECT name
    FROM sys.databases
    WHERE state        = 0
      AND is_read_only = 0
      AND database_id  > 4
      AND (@SoloBaseDatos IS NULL OR name = @SoloBaseDatos)
    ORDER BY name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DBName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        INSERT INTO #ScriptOutput (Line) VALUES
            (N''),
            (N'/* ------------------------------------------------------------------ */'),
            (N'/* BASE DE DATOS: ' + @DBName + N'                                    */'),
            (N'/* ------------------------------------------------------------------ */'),
            (N'-- NOTA: Si esta BD no existe (Msg 911) o es read-only (Msg 3906) en   '),
            (N'-- el servidor de destino, omita o comente esta sección completa.       '),
            (N'USE ' + QUOTENAME(@DBName) + N';'),
            (N'GO'),
            (N'');

        /*
         * sp_executesql corre en el contexto de @DBName pero comparte la
         * sesión, por lo que #ScriptOutput sigue siendo visible.
         */
        SET @SQLDynamic = N'
        USE ' + QUOTENAME(@DBName) + N';

        /* ================================================================
         * A. USUARIOS
         *
         * Tres escenarios para usuarios de tipo SQL (S):
         *
         *  1. Usuario con login coincidente por SID → CREATE USER FOR LOGIN.
         *     Al haberse creado el login con el SID original (sección 1),
         *     este CREATE USER queda correctamente vinculado.
         *
         *  2. Usuario huérfano con login de IGUAL NOMBRE en el servidor →
         *     ALTER USER WITH LOGIN (reemplaza a sp_change_users_login).
         *     Repara la vinculación tras un restore donde el SID del login
         *     difiere del SID guardado en la BD.
         *
         *  3. Usuario huérfano sin ningún login relacionado →
         *     Comentario de advertencia; el DBA decide si crearlo WITHOUT LOGIN
         *     o asignarlo a un login nuevo.
         *
         * Para usuarios Windows (U/G) el enlace es siempre por SID;
         * ALTER USER WITH LOGIN no aplica a ese tipo.
         * ================================================================ */
        INSERT INTO #ScriptOutput (Line)
        SELECT
            N''/* --- USUARIO: '' + dp.name + N'' ('' + dp.type_desc + N'') --- */'' + CHAR(13)+CHAR(10)

            /* ---- rama CREATE (usuario no existe en destino) ---- */
            + N''IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''
                + QUOTENAME(dp.name, '''''''') + N'')''
            + CHAR(13)+CHAR(10)
            + N''BEGIN'' + CHAR(13)+CHAR(10)
            + CASE
                /* Escenario 1: SQL user con login por SID */
                WHEN dp.type = ''S'' AND sp.name IS NOT NULL THEN
                    N''    CREATE USER '' + QUOTENAME(dp.name)
                    + N'' FOR LOGIN '' + QUOTENAME(sp.name)
                    + ISNULL(N'' WITH DEFAULT_SCHEMA = '' + QUOTENAME(dp.default_schema_name), N'''')
                    + N'';''
                /* Escenario 2: huérfano con login del mismo nombre en el servidor */
                WHEN dp.type = ''S'' AND sp.name IS NULL
                     AND EXISTS (
                         SELECT 1 FROM master.sys.server_principals sp2
                         WHERE sp2.name COLLATE DATABASE_DEFAULT = dp.name COLLATE DATABASE_DEFAULT
                           AND sp2.type COLLATE DATABASE_DEFAULT = ''S''
                     ) THEN
                    N''    -- AVISO: SID mismatch. Se crea el usuario y se reconecta al login del mismo nombre.''
                    + CHAR(13)+CHAR(10)
                    + N''    CREATE USER '' + QUOTENAME(dp.name)
                    + N'' FOR LOGIN '' + QUOTENAME(dp.name)
                    + ISNULL(N'' WITH DEFAULT_SCHEMA = '' + QUOTENAME(dp.default_schema_name), N'''')
                    + N'';''
                /* Escenario 3: huérfano sin login relacionado.
                 * BEGIN/END no puede contener sólo comentarios (parser error);
                 * se usa RAISERROR informativo (sev 10) como sentencia real. */
                WHEN dp.type = ''S'' AND sp.name IS NULL THEN
                    N''    RAISERROR(N''''AVISO: usuario huerfano sin login. Crear manualmente si aplica.'''', 10, 1) WITH NOWAIT;''
                    + CHAR(13)+CHAR(10)
                    + N''    -- (a) CREATE USER '' + QUOTENAME(dp.name) + N'' WITHOUT LOGIN;''
                    + CHAR(13)+CHAR(10)
                    + N''    -- (b) CREATE USER '' + QUOTENAME(dp.name) + N'' FOR LOGIN [<login_destino>];''
                /* Windows usuario o grupo */
                WHEN dp.type IN (''U'', ''G'') THEN
                    N''    CREATE USER '' + QUOTENAME(dp.name)
                    + N'' FOR LOGIN '' + QUOTENAME(ISNULL(sp.name, dp.name))
                    + ISNULL(N'' WITH DEFAULT_SCHEMA = '' + QUOTENAME(dp.default_schema_name), N'''')
                    + N'';''
                ELSE
                    N''    RAISERROR(N''''AVISO: tipo de usuario no contemplado.'''', 10, 1) WITH NOWAIT;''
                    + N''    -- type_desc: '' + dp.type_desc
              END
            + CHAR(13)+CHAR(10)
            + N''END'' + CHAR(13)+CHAR(10)

            /* ---- rama ALTER USER (usuario ya existe en destino) ---- */
            + N''ELSE'' + CHAR(13)+CHAR(10)
            + N''BEGIN'' + CHAR(13)+CHAR(10)
            + CASE
                /* Actualizar esquema por defecto */
                WHEN dp.default_schema_name IS NOT NULL THEN
                    N''    ALTER USER '' + QUOTENAME(dp.name)
                    + N'' WITH DEFAULT_SCHEMA = '' + QUOTENAME(dp.default_schema_name) + N'';''
                ELSE
                    /* BEGIN/END con sólo comentario es inválido; se usa sentencia real */
                    N''    RAISERROR(N''''INFO: El usuario ya existe; esquema por defecto NULL, sin cambios.'''', 10, 1) WITH NOWAIT;''
              END
            + CHAR(13)+CHAR(10)
            + N''END;'' + CHAR(13)+CHAR(10)

            /*
             * ALTER USER WITH LOGIN: reemplaza a sp_change_users_login.
             * Garantiza que el database user quede vinculado al login correcto
             * incluso si los SIDs difieren (escenario post-restore típico).
             * Solo aplica a usuarios SQL con login conocido en el servidor.
             */
            + CASE
                WHEN dp.type = ''S'' AND sp.name IS NOT NULL THEN
                    N''ALTER USER '' + QUOTENAME(dp.name)
                    + N'' WITH LOGIN = '' + QUOTENAME(sp.name) + N'';'' + CHAR(13)+CHAR(10)
                WHEN dp.type = ''S'' AND sp.name IS NULL
                     AND EXISTS (
                         SELECT 1 FROM master.sys.server_principals sp2
                         WHERE sp2.name COLLATE DATABASE_DEFAULT = dp.name COLLATE DATABASE_DEFAULT
                           AND sp2.type COLLATE DATABASE_DEFAULT = ''S''
                     ) THEN
                    N''ALTER USER '' + QUOTENAME(dp.name)
                    + N'' WITH LOGIN = '' + QUOTENAME(dp.name) + N'';'' + CHAR(13)+CHAR(10)
                ELSE N''''
              END

            + N''GO''
        FROM sys.database_principals dp
        LEFT JOIN master.sys.server_principals sp ON dp.sid = sp.sid
        WHERE dp.type IN (''S'', ''U'', ''G'')
          AND dp.principal_id > 4
          AND dp.name COLLATE DATABASE_DEFAULT NOT IN (''guest'', ''INFORMATION_SCHEMA'', ''sys'')
          AND dp.name COLLATE DATABASE_DEFAULT NOT LIKE ''##%'';

        /* ================================================================
         * B. MEMBRESÍA EN ROLES DE BASE DE DATOS
         *    IS_ROLEMEMBER: 1=miembro, 0=no miembro, NULL=no existe.
         *    Se usa = 0 para no ejecutar ALTER cuando retorna NULL.
         * ================================================================ */
        INSERT INTO #ScriptOutput (Line)
        SELECT
            N''IF IS_ROLEMEMBER('' + QUOTENAME(r.name, '''''''') + N'', '' + QUOTENAME(u.name, '''''''') + N'') = 0''
            + CHAR(13)+CHAR(10)
            + N''    ALTER ROLE '' + QUOTENAME(r.name) + N'' ADD MEMBER '' + QUOTENAME(u.name) + N'';''
            + CHAR(13)+CHAR(10)
            + N''GO''
        FROM sys.database_role_members drm
        INNER JOIN sys.database_principals r ON drm.role_principal_id  = r.principal_id
        INNER JOIN sys.database_principals u ON drm.member_principal_id = u.principal_id
        WHERE u.principal_id > 4
          AND u.name COLLATE DATABASE_DEFAULT NOT IN (''guest'', ''INFORMATION_SCHEMA'', ''sys'')
          AND u.name COLLATE DATABASE_DEFAULT NOT LIKE ''##%'';

        /* ================================================================
         * C. PERMISOS A NIVEL DE BASE DE DATOS (clase 0)
         *    CONNECT (tipo CO) es implícito y se excluye.
         * ================================================================ */
        INSERT INTO #ScriptOutput (Line)
        SELECT
            CASE dp.state
                WHEN ''W'' THEN N''GRANT '' + dp.permission_name + N'' TO '' + QUOTENAME(usr.name) + N'' WITH GRANT OPTION;''
                WHEN ''G'' THEN N''GRANT '' + dp.permission_name + N'' TO '' + QUOTENAME(usr.name) + N'';''
                WHEN ''D'' THEN N''DENY ''  + dp.permission_name + N'' TO '' + QUOTENAME(usr.name) + N'';''
            END
            + CHAR(13)+CHAR(10)
            + N''GO''
        FROM sys.database_permissions dp
        INNER JOIN sys.database_principals usr ON dp.grantee_principal_id = usr.principal_id
        WHERE dp.class = 0
          AND dp.state IN (''G'', ''D'', ''W'')
          AND usr.principal_id > 4
          AND usr.name COLLATE DATABASE_DEFAULT NOT IN (''guest'', ''INFORMATION_SCHEMA'', ''sys'')
          AND usr.name COLLATE DATABASE_DEFAULT NOT LIKE ''##%''
          AND dp.type <> ''CO'';

        /* ================================================================
         * D. PERMISOS SOBRE ESQUEMAS (clase 3)
         * ================================================================ */
        INSERT INTO #ScriptOutput (Line)
        SELECT
            CASE dp.state
                WHEN ''W'' THEN N''GRANT '' + dp.permission_name + N'' ON SCHEMA::'' + QUOTENAME(sch.name) + N'' TO '' + QUOTENAME(usr.name) + N'' WITH GRANT OPTION;''
                WHEN ''G'' THEN N''GRANT '' + dp.permission_name + N'' ON SCHEMA::'' + QUOTENAME(sch.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
                WHEN ''D'' THEN N''DENY ''  + dp.permission_name + N'' ON SCHEMA::'' + QUOTENAME(sch.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
            END
            + CHAR(13)+CHAR(10)
            + N''GO''
        FROM sys.database_permissions dp
        INNER JOIN sys.database_principals usr ON dp.grantee_principal_id = usr.principal_id
        INNER JOIN sys.schemas sch ON dp.major_id = sch.schema_id
        WHERE dp.class = 3
          AND dp.state IN (''G'', ''D'', ''W'')
          AND usr.principal_id > 4
          AND usr.name COLLATE DATABASE_DEFAULT NOT IN (''guest'', ''INFORMATION_SCHEMA'', ''sys'')
          AND usr.name COLLATE DATABASE_DEFAULT NOT LIKE ''##%'';

        /* ================================================================
         * E. PERMISOS SOBRE OBJETOS Y COLUMNAS (clase 1)
         *
         *    minor_id = 0  → permiso sobre el objeto completo
         *    minor_id > 0  → permiso a nivel de columna
         *
         *    CORRECCIÓN: en la versión original la rama ELSE del CASE omitía
         *    "TO <usuario>", generando sentencias sin destinatario que fallan
         *    al ejecutarse en el servidor de destino.
         * ================================================================ */
        INSERT INTO #ScriptOutput (Line)
        SELECT
            CASE
                WHEN dp.minor_id = 0 THEN
                    CASE dp.state
                        WHEN ''W'' THEN N''GRANT '' + dp.permission_name + N'' ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'' WITH GRANT OPTION;''
                        WHEN ''G'' THEN N''GRANT '' + dp.permission_name + N'' ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
                        WHEN ''D'' THEN N''DENY ''  + dp.permission_name + N'' ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
                    END
                ELSE
                    CASE dp.state
                        WHEN ''W'' THEN N''GRANT '' + dp.permission_name + N'' ('' + QUOTENAME(COL_NAME(obj.object_id, dp.minor_id)) + N'') ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'' WITH GRANT OPTION;''
                        WHEN ''G'' THEN N''GRANT '' + dp.permission_name + N'' ('' + QUOTENAME(COL_NAME(obj.object_id, dp.minor_id)) + N'') ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
                        WHEN ''D'' THEN N''DENY ''  + dp.permission_name + N'' ('' + QUOTENAME(COL_NAME(obj.object_id, dp.minor_id)) + N'') ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
                    END
            END
            + CHAR(13)+CHAR(10)
            + N''GO''
        FROM sys.database_permissions dp
        INNER JOIN sys.database_principals usr ON dp.grantee_principal_id = usr.principal_id
        INNER JOIN sys.objects obj ON dp.major_id   = obj.object_id
        INNER JOIN sys.schemas sch ON obj.schema_id = sch.schema_id
        WHERE dp.class = 1
          AND dp.state IN (''G'', ''D'', ''W'')
          AND usr.principal_id > 4
          AND usr.name COLLATE DATABASE_DEFAULT NOT IN (''guest'', ''INFORMATION_SCHEMA'', ''sys'')
          AND usr.name COLLATE DATABASE_DEFAULT NOT LIKE ''##%'';
        ';

        EXEC sp_executesql @SQLDynamic;

        FETCH NEXT FROM db_cursor INTO @DBName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    /* ====================================================================
       5. DEVOLUCIÓN DEL SCRIPT POR FILAS
          Una fila = una línea del script generado.
          En SSMS use Ctrl+T (Results to Text) antes de ejecutar para
          copiar/pegar el bloque completo sin truncado de celda.
       ==================================================================== */
    SELECT Line FROM #ScriptOutput ORDER BY Id;

    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'db_cursor') >= 0 BEGIN CLOSE db_cursor; DEALLOCATE db_cursor; END;

        IF OBJECT_ID('tempdb..#ScriptOutput') IS NOT NULL
            DROP TABLE #ScriptOutput;

        DECLARE @ErrMsg  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev  INT            = ERROR_SEVERITY();
        DECLARE @ErrStat INT            = ERROR_STATE();
        RAISERROR(@ErrMsg, @ErrSev, @ErrStat);
        RETURN;
    END CATCH;

    IF OBJECT_ID('tempdb..#ScriptOutput') IS NOT NULL
        DROP TABLE #ScriptOutput;
END;
GO

/*
=============================================================================
  EJEMPLOS DE USO
=============================================================================

-- 1. Script completo (todas las BBDDs, logins SQL + Windows):
EXEC dbo.sp_GenerarScriptUsuarios;

-- 2. Solo logins SQL Server (sin Windows):
EXEC dbo.sp_GenerarScriptUsuarios
    @IncluirWindowsLogins = 0;

-- 3. Solo logins Windows (sin SQL):
EXEC dbo.sp_GenerarScriptUsuarios
    @IncluirSQLLogins = 0;

-- 4. Solo una base de datos (útil en migraciones parciales):
EXEC dbo.sp_GenerarScriptUsuarios
    @SoloBaseDatos = N'MiBaseDeDatos';

-- 5. Solo una BD, solo logins SQL:
EXEC dbo.sp_GenerarScriptUsuarios
    @IncluirWindowsLogins = 0,
    @SoloBaseDatos        = N'MiBaseDeDatos';

-- CONSEJO: en SSMS active Ctrl+T (Results to Text) antes de ejecutar
--          para copiar/pegar el script completo sin truncado de celda.

=============================================================================
*/
