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
  @IncluirSQLLogins     BIT      = 1   Incluye logins de tipo SQL Server
  @IncluirWindowsLogins BIT      = 1   Incluye logins Windows (usuario y grupo)
  @SoloBaseDatos        sysname  = NULL Restringe la sección 4 a una BD concreta;
                                        NULL = todas las BBDDs de usuario online

  Notas
  -----
  - El script generado es IDEMPOTENTE: puede ejecutarse varias veces sin error.
  - Los logins marcados como deshabilitados se reconstruyen deshabilitados.
  - Los usuarios huérfanos (sin login en el servidor) se señalan con un comentario
    de advertencia; no se genera un CREATE USER que fallaría en destino.
  - Permisos con estado R (REVOKE implícito) no se scriptan porque no son
    concesiones/denegaciones explícitas.
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
        Line NVARCHAR(MAX)
    );

    BEGIN TRY

    /* ------------------------------------------------------------------ */
    /* ENCABEZADO DEL SCRIPT GENERADO                                      */
    /* ------------------------------------------------------------------ */
    INSERT INTO #ScriptOutput (Line) VALUES
        (N'/*=================================================================='),
        (N'  SCRIPT DE SINCRONIZACIÓN DE LOGINS, USUARIOS Y PERMISOS'),
        (N'  Servidor Origen : ' + @@SERVERNAME),
        (N'  Fecha Generación: ' + CONVERT(VARCHAR(20), GETDATE(), 120)),
        (N'  Compatibilidad  : SQL Server 2012 – 2022'),
        (N'  Idempotente     : Sí – apto para servidor de contingencia'),
        (N'==================================================================*/'),
        (N''),
        (N'USE [master];'),
        (N'GO'),
        (N'');

    /* ================================================================== */
    /* 1. LOGINS (SQL Server, Windows usuario y Windows grupo)             */
    /* ================================================================== */
    INSERT INTO #ScriptOutput (Line) VALUES
        (N'/* ================================================================== */'),
        (N'/* 1. LOGINS                                                          */'),
        (N'/* ================================================================== */'),
        (N'');

    INSERT INTO #ScriptOutput (Line)
    SELECT
        N'/* --- LOGIN: ' + sp.name + N' (' + sp.type_desc COLLATE DATABASE_DEFAULT + N') --- */'
        + CHAR(13)+CHAR(10)
        /*
         * Bloque CREATE: sólo si el login no existe todavía.
         * Para logins SQL se incluye el hash de contraseña y el SID original
         * para evitar usuarios huérfanos en las BBDDs ya migradas.
         */
        + N'IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '
            + QUOTENAME(sp.name, '''') + N')'
        + CHAR(13)+CHAR(10) + N'BEGIN' + CHAR(13)+CHAR(10)
        + CASE sp.type
            WHEN 'S' THEN
                N'    CREATE LOGIN ' + QUOTENAME(sp.name)
                + N' WITH PASSWORD = ' + CONVERT(NVARCHAR(MAX), sl.password_hash, 1) + N' HASHED'
                + N', SID = '                + CONVERT(NVARCHAR(MAX), sp.sid, 1)
                + N', DEFAULT_DATABASE = '   + QUOTENAME(ISNULL(sp.default_database_name, N'master'))
                + N', DEFAULT_LANGUAGE = '   + QUOTENAME(ISNULL(sp.default_language_name, N'us_english'))
                + N', CHECK_POLICY = '       + CASE WHEN sl.is_policy_checked    = 1 THEN N'ON' ELSE N'OFF' END
                + N', CHECK_EXPIRATION = '   + CASE WHEN sl.is_expiration_checked = 1 THEN N'ON' ELSE N'OFF' END
                + N';'
            WHEN 'U' THEN
                N'    CREATE LOGIN ' + QUOTENAME(sp.name) + N' FROM WINDOWS'
                + N' WITH DEFAULT_DATABASE = ' + QUOTENAME(ISNULL(sp.default_database_name, N'master'))
                + N', DEFAULT_LANGUAGE = '     + QUOTENAME(ISNULL(sp.default_language_name, N'us_english'))
                + N';'
            WHEN 'G' THEN
                N'    CREATE LOGIN ' + QUOTENAME(sp.name) + N' FROM WINDOWS'
                + N' WITH DEFAULT_DATABASE = ' + QUOTENAME(ISNULL(sp.default_database_name, N'master'))
                + N', DEFAULT_LANGUAGE = '     + QUOTENAME(ISNULL(sp.default_language_name, N'us_english'))
                + N';'
          END
        + CHAR(13)+CHAR(10) + N'END' + CHAR(13)+CHAR(10)
        /*
         * Bloque ELSE: el login ya existe → actualizar propiedades sin tocar
         * la contraseña (evita romper sesiones activas en el destino).
         */
        + N'ELSE' + CHAR(13)+CHAR(10) + N'BEGIN' + CHAR(13)+CHAR(10)
        + N'    ALTER LOGIN ' + QUOTENAME(sp.name)
        + N' WITH DEFAULT_DATABASE = ' + QUOTENAME(ISNULL(sp.default_database_name, N'master'))
        + N', DEFAULT_LANGUAGE = '     + QUOTENAME(ISNULL(sp.default_language_name, N'us_english'))
        + CASE sp.type
            WHEN 'S' THEN
                N', CHECK_POLICY = '     + CASE WHEN sl.is_policy_checked    = 1 THEN N'ON' ELSE N'OFF' END
                + N', CHECK_EXPIRATION = ' + CASE WHEN sl.is_expiration_checked = 1 THEN N'ON' ELSE N'OFF' END
            ELSE N''
          END
        + N';' + CHAR(13)+CHAR(10)
        + N'END;' + CHAR(13)+CHAR(10)
        /* Estado habilitado / deshabilitado */
        + CASE WHEN sp.is_disabled = 1
            THEN N'ALTER LOGIN ' + QUOTENAME(sp.name) + N' DISABLE;'
            ELSE N'ALTER LOGIN ' + QUOTENAME(sp.name) + N' ENABLE;'
          END
        + CHAR(13)+CHAR(10) + N'GO'
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

    /* ================================================================== */
    /* 2. MEMBRESÍA EN ROLES DE SERVIDOR                                   */
    /* ================================================================== */
    INSERT INTO #ScriptOutput (Line) VALUES
        (N''),
        (N'/* ================================================================== */'),
        (N'/* 2. MEMBRESÍA EN ROLES DE SERVIDOR                                  */'),
        (N'/* ================================================================== */'),
        (N'');

    INSERT INTO #ScriptOutput (Line)
    SELECT
        N'/* ' + m.name + N' → ' + r.name + N' */' + CHAR(13)+CHAR(10)
        /*
         * IS_SRVROLEMEMBER devuelve: 1 = miembro, 0 = no miembro, NULL = error.
         * Usar = 0 (en vez de <> 1) para no ejecutar ALTER cuando retorna NULL.
         */
        + N'IF IS_SRVROLEMEMBER(' + QUOTENAME(r.name, '''') + N', ' + QUOTENAME(m.name, '''') + N') = 0'
        + CHAR(13)+CHAR(10)
        + N'    ALTER SERVER ROLE ' + QUOTENAME(r.name) + N' ADD MEMBER ' + QUOTENAME(m.name) + N';'
        + CHAR(13)+CHAR(10) + N'GO'
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

    /* ================================================================== */
    /* 3. PERMISOS EXPLÍCITOS A NIVEL DE SERVIDOR                          */
    /* ================================================================== */
    INSERT INTO #ScriptOutput (Line) VALUES
        (N''),
        (N'/* ================================================================== */'),
        (N'/* 3. PERMISOS EXPLÍCITOS DE SERVIDOR                                 */'),
        (N'/* ================================================================== */'),
        (N'');

    INSERT INTO #ScriptOutput (Line)
    SELECT
        /*
         * Usar spm.state (char) en vez de spm.state_desc (varchar) para evitar
         * comparaciones de texto largas y ser independiente del idioma del servidor.
         * Estado R = REVOKE implícito → no se scriptea (no es concesión/denegación
         * explícita y la sintaxis REVOKE ... FROM es diferente a GRANT/DENY ... TO).
         */
        CASE spm.state
            WHEN 'W' THEN N'GRANT '  + spm.permission_name + N' TO ' + QUOTENAME(sp.name) + N' WITH GRANT OPTION;'
            WHEN 'G' THEN N'GRANT '  + spm.permission_name + N' TO ' + QUOTENAME(sp.name) + N';'
            WHEN 'D' THEN N'DENY '   + spm.permission_name + N' TO ' + QUOTENAME(sp.name) + N';'
        END
        + CHAR(13)+CHAR(10) + N'GO'
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
      AND spm.state IN ('G', 'D', 'W')     -- excluir REVOKE implícito (R)
      AND spm.type  <> 'COSQ'              -- excluir CONNECT SQL (implícito para todo login válido)
    ORDER BY sp.name, spm.permission_name;

    /* ================================================================== */
    /* 4. USUARIOS, ROLES Y PERMISOS POR BASE DE DATOS                     */
    /* ================================================================== */
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
    WHERE state         = 0     -- ONLINE
      AND is_read_only  = 0
      AND database_id   > 4     -- excluir master, tempdb, model, msdb
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
            (N'USE ' + QUOTENAME(@DBName) + N';'),
            (N'GO'),
            (N'');

        /*
         * El SQL dinámico corre en el contexto de @DBName.
         * #ScriptOutput es visible porque fue creada en la misma sesión
         * (las tablas temporales son compartidas por la sesión, no por el batch).
         */
        SET @SQLDynamic = N'
        USE ' + QUOTENAME(@DBName) + N';

        /* ----------------------------------------------------------------
         * A. CREAR USUARIO (si no existe) / ACTUALIZAR ESQUEMA (si existe)
         * ---------------------------------------------------------------- */
        INSERT INTO #ScriptOutput (Line)
        SELECT
            N''/* --- USUARIO: '' + dp.name + N'' ('' + dp.type_desc + N'') --- */'' + CHAR(13)+CHAR(10)
            + N''IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''
                + QUOTENAME(dp.name, '''''') + N'')''
            + CHAR(13)+CHAR(10) + N''BEGIN'' + CHAR(13)+CHAR(10)
            + CASE
                /*
                 * Usuario SQL con login correspondiente en el servidor.
                 * Se usa el nombre del server principal (sp.name) para enlazarlo
                 * aunque el nombre de usuario en la BD sea diferente.
                 */
                WHEN dp.type = ''S'' AND sp.name IS NOT NULL THEN
                    N''    CREATE USER '' + QUOTENAME(dp.name)
                    + N'' FOR LOGIN '' + QUOTENAME(sp.name)
                    + ISNULL(N'' WITH DEFAULT_SCHEMA = '' + QUOTENAME(dp.default_schema_name), N'''')
                    + N'';''
                /*
                 * Usuario huérfano: existe en la BD pero su SID no tiene login en
                 * este servidor. Se genera un comentario de advertencia para que el
                 * DBA decida si debe crearlo WITHOUT LOGIN o asignarle un login nuevo.
                 */
                WHEN dp.type = ''S'' AND sp.name IS NULL THEN
                    N''    -- ADVERTENCIA: usuario huérfano sin login en el servidor.''
                    + CHAR(13)+CHAR(10)
                    + N''    -- Opciones: CREATE USER '' + QUOTENAME(dp.name)
                    + N'' WITHOUT LOGIN; -- o asignar a un login existente.''
                /* Windows usuario o grupo */
                WHEN dp.type IN (''U'', ''G'') THEN
                    N''    CREATE USER '' + QUOTENAME(dp.name)
                    + N'' FOR LOGIN '' + QUOTENAME(ISNULL(sp.name, dp.name))
                    + ISNULL(N'' WITH DEFAULT_SCHEMA = '' + QUOTENAME(dp.default_schema_name), N'''')
                    + N'';''
                ELSE
                    N''    -- Tipo de usuario no manejado: '' + dp.type_desc
              END
            + CHAR(13)+CHAR(10) + N''END'' + CHAR(13)+CHAR(10)
            /*
             * Si el usuario ya existe, actualizar sólo el esquema por defecto
             * para mantener la idempotencia sin recrear el usuario.
             */
            + N''ELSE'' + CHAR(13)+CHAR(10) + N''BEGIN'' + CHAR(13)+CHAR(10)
            + CASE
                WHEN dp.default_schema_name IS NOT NULL THEN
                    N''    ALTER USER '' + QUOTENAME(dp.name)
                    + N'' WITH DEFAULT_SCHEMA = '' + QUOTENAME(dp.default_schema_name) + N'';''
                ELSE
                    N''    -- (esquema por defecto NULL – sin cambios necesarios)''
              END
            + CHAR(13)+CHAR(10) + N''END;'' + CHAR(13)+CHAR(10)
            + N''GO''
        FROM sys.database_principals dp
        LEFT JOIN master.sys.server_principals sp ON dp.sid = sp.sid
        WHERE dp.type IN (''S'', ''U'', ''G'')
          AND dp.principal_id > 4
          AND dp.name NOT IN (''guest'', ''INFORMATION_SCHEMA'', ''sys'')
          AND dp.name NOT LIKE ''##%'';

        /* ----------------------------------------------------------------
         * B. MEMBRESÍA EN ROLES DE BASE DE DATOS
         * ---------------------------------------------------------------- */
        INSERT INTO #ScriptOutput (Line)
        SELECT
            /*
             * IS_ROLEMEMBER devuelve: 1 = miembro, 0 = no miembro, NULL = rol/usuario
             * inexistente. Se usa = 0 para ejecutar ALTER sólo cuando se sabe con
             * certeza que el usuario NO es miembro (evita error con NULL).
             */
            N''IF IS_ROLEMEMBER('' + QUOTENAME(r.name, '''''') + N'', '' + QUOTENAME(u.name, '''''') + N'') = 0''
            + CHAR(13)+CHAR(10)
            + N''    ALTER ROLE '' + QUOTENAME(r.name) + N'' ADD MEMBER '' + QUOTENAME(u.name) + N'';''
            + CHAR(13)+CHAR(10) + N''GO''
        FROM sys.database_role_members drm
        INNER JOIN sys.database_principals r ON drm.role_principal_id  = r.principal_id
        INNER JOIN sys.database_principals u ON drm.member_principal_id = u.principal_id
        WHERE u.principal_id > 4
          AND u.name NOT IN (''guest'', ''INFORMATION_SCHEMA'', ''sys'')
          AND u.name NOT LIKE ''##%'';

        /* ----------------------------------------------------------------
         * C. PERMISOS EXPLÍCITOS A NIVEL DE BASE DE DATOS (clase 0)
         * ---------------------------------------------------------------- */
        INSERT INTO #ScriptOutput (Line)
        SELECT
            CASE dp.state
                WHEN ''W'' THEN N''GRANT '' + dp.permission_name + N'' TO '' + QUOTENAME(usr.name) + N'' WITH GRANT OPTION;''
                WHEN ''G'' THEN N''GRANT '' + dp.permission_name + N'' TO '' + QUOTENAME(usr.name) + N'';''
                WHEN ''D'' THEN N''DENY ''  + dp.permission_name + N'' TO '' + QUOTENAME(usr.name) + N'';''
            END
            + CHAR(13)+CHAR(10) + N''GO''
        FROM sys.database_permissions dp
        INNER JOIN sys.database_principals usr ON dp.grantee_principal_id = usr.principal_id
        WHERE dp.class     =  0
          AND dp.state     IN (''G'', ''D'', ''W'')
          AND usr.principal_id > 4
          AND usr.name NOT IN (''guest'', ''INFORMATION_SCHEMA'', ''sys'')
          AND usr.name NOT LIKE ''##%''
          AND dp.type      <> ''CO'';           -- excluir CONNECT (implícito)

        /* ----------------------------------------------------------------
         * D. PERMISOS SOBRE ESQUEMAS (clase 3)
         * ---------------------------------------------------------------- */
        INSERT INTO #ScriptOutput (Line)
        SELECT
            CASE dp.state
                WHEN ''W'' THEN N''GRANT '' + dp.permission_name + N'' ON SCHEMA::'' + QUOTENAME(sch.name) + N'' TO '' + QUOTENAME(usr.name) + N'' WITH GRANT OPTION;''
                WHEN ''G'' THEN N''GRANT '' + dp.permission_name + N'' ON SCHEMA::'' + QUOTENAME(sch.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
                WHEN ''D'' THEN N''DENY ''  + dp.permission_name + N'' ON SCHEMA::'' + QUOTENAME(sch.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
            END
            + CHAR(13)+CHAR(10) + N''GO''
        FROM sys.database_permissions dp
        INNER JOIN sys.database_principals usr ON dp.grantee_principal_id = usr.principal_id
        INNER JOIN sys.schemas sch ON dp.major_id = sch.schema_id
        WHERE dp.class  = 3
          AND dp.state  IN (''G'', ''D'', ''W'')
          AND usr.principal_id > 4
          AND usr.name NOT IN (''guest'', ''INFORMATION_SCHEMA'', ''sys'')
          AND usr.name NOT LIKE ''##%'';

        /* ----------------------------------------------------------------
         * E. PERMISOS SOBRE OBJETOS Y COLUMNAS (clase 1)
         *
         * BUG ORIGINAL CORREGIDO: la rama ELSE carecía de "TO <usuario>",
         * produciendo sentencias GRANT/DENY sin destinatario que fallarían
         * al ejecutarse en el servidor de destino.
         * ---------------------------------------------------------------- */
        INSERT INTO #ScriptOutput (Line)
        SELECT
            CASE
                /* Permiso a nivel de objeto completo */
                WHEN dp.minor_id = 0 THEN
                    CASE dp.state
                        WHEN ''W'' THEN N''GRANT '' + dp.permission_name + N'' ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'' WITH GRANT OPTION;''
                        WHEN ''G'' THEN N''GRANT '' + dp.permission_name + N'' ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
                        WHEN ''D'' THEN N''DENY ''  + dp.permission_name + N'' ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
                    END
                /* Permiso a nivel de columna */
                ELSE
                    CASE dp.state
                        WHEN ''W'' THEN N''GRANT '' + dp.permission_name + N'' ('' + QUOTENAME(COL_NAME(obj.object_id, dp.minor_id)) + N'') ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'' WITH GRANT OPTION;''
                        WHEN ''G'' THEN N''GRANT '' + dp.permission_name + N'' ('' + QUOTENAME(COL_NAME(obj.object_id, dp.minor_id)) + N'') ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
                        WHEN ''D'' THEN N''DENY ''  + dp.permission_name + N'' ('' + QUOTENAME(COL_NAME(obj.object_id, dp.minor_id)) + N'') ON OBJECT::'' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(obj.name) + N'' TO '' + QUOTENAME(usr.name) + N'';''
                    END
            END
            + CHAR(13)+CHAR(10) + N''GO''
        FROM sys.database_permissions dp
        INNER JOIN sys.database_principals usr ON dp.grantee_principal_id = usr.principal_id
        INNER JOIN sys.objects obj ON dp.major_id    = obj.object_id
        INNER JOIN sys.schemas sch ON obj.schema_id  = sch.schema_id
        WHERE dp.class  = 1
          AND dp.state  IN (''G'', ''D'', ''W'')
          AND usr.principal_id > 4
          AND usr.name NOT IN (''guest'', ''INFORMATION_SCHEMA'', ''sys'')
          AND usr.name NOT LIKE ''##%'';
        ';

        EXEC sp_executesql @SQLDynamic;

        FETCH NEXT FROM db_cursor INTO @DBName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    /* ================================================================== */
    /* 5. DEVOLUCIÓN DEL SCRIPT COMPLETO                                   */
    /* ================================================================== */
    SELECT Line FROM #ScriptOutput ORDER BY Id;

    END TRY
    BEGIN CATCH
        /* Limpiar recursos antes de relanzar el error */
        IF CURSOR_STATUS('local', 'db_cursor') >= 0
        BEGIN
            CLOSE     db_cursor;
            DEALLOCATE db_cursor;
        END;

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

  -- Generar script completo (logins SQL y Windows, todas las BBDDs):
  EXEC dbo.sp_GenerarScriptUsuarios;

  -- Solo logins SQL:
  EXEC dbo.sp_GenerarScriptUsuarios @IncluirWindowsLogins = 0;

  -- Solo una base de datos (útil para migraciones parciales):
  EXEC dbo.sp_GenerarScriptUsuarios @SoloBaseDatos = N'MiBaseDeDatos';

  -- Copiar resultado al portapapeles:
  -- En SSMS: Results to Text (Ctrl+T) antes de ejecutar.
=============================================================================
*/
