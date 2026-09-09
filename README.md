# Prueba-Revisi-n-Codigo

Scripts de administración para auditar permisos en entornos Windows.

| Script | Para qué sirve |
| --- | --- |
| `sp_GenerarScriptUsuarios.sql` | Procedimiento de SQL Server que genera un script idempotente con logins, usuarios, roles y permisos para replicarlos en otro servidor. |
| `Get-PermisosCarpetasCompartidas.ps1` | Audita un servidor de archivos y lista qué usuarios tienen permiso sobre cada carpeta, y a qué carpetas llega cada usuario. |

## Get-PermisosCarpetasCompartidas.ps1

Dada una ubicación como `\\10.10.1.65`, enumera los recursos compartidos, lee
los permisos de compartición (SMB) y los permisos NTFS de cada carpeta, y
produce dos informes: **permisos por carpeta** y **carpetas por usuario**.

### Requisitos

- Windows PowerShell 5.1 o PowerShell 7 sobre Windows.
- Permiso de lectura sobre los recursos y sus ACL. Los permisos de
  compartición y los recursos administrativos (`C$`, `ADMIN$`) requieren ser
  administrador local del servidor auditado.
- Puerto SMB (445) y, para la enumeración por CIM/WMI, WinRM (5985) o
  DCOM/RPC (135 más el rango dinámico). Si CIM no responde, el script cae a
  `net view` y continúa solo con los permisos NTFS.

### Uso

```powershell
# Recursos del servidor y quién tiene permiso en la raíz de cada uno
.\Get-PermisosCarpetasCompartidas.ps1 -Servidor \\10.10.1.65

# Dos niveles de subcarpetas, resolviendo grupos a usuarios, exportando a CSV
.\Get-PermisosCarpetasCompartidas.ps1 -Servidor 10.10.1.65 -Profundidad 2 `
    -ExpandirGrupos -CarpetaSalida C:\Auditoria

# ¿A qué carpetas llega un usuario concreto?
.\Get-PermisosCarpetasCompartidas.ps1 -Servidor 10.10.1.65 -Profundidad 3 `
    -ExpandirGrupos -SoloUsuario '*jperez*'

# Con credenciales alternativas y solo algunos recursos
.\Get-PermisosCarpetasCompartidas.ps1 -Servidor 10.10.1.65 `
    -Recurso 'Conta*', 'RRHH' -Credencial (Get-Credential DOMINIO\auditor)
```

### Parámetros

| Parámetro | Descripción |
| --- | --- |
| `-Servidor` | Nombre o IP del servidor. Admite `\\10.10.1.65`. |
| `-Recurso` | Recursos a auditar, con comodines. Por defecto, todos. |
| `-Profundidad` | Niveles de subcarpetas bajo la raíz del recurso. `0` = solo la raíz. |
| `-SoloUsuario` | Filtra el informe a una o varias identidades, con comodines. |
| `-IncluirRecursosAdministrativos` | Incluye `C$`, `ADMIN$`, `IPC$`, `print$`. |
| `-IncluirHeredados` | Incluye las ACE heredadas del padre (por defecto solo las explícitas). |
| `-IncluirCuentasSistema` | Incluye SYSTEM, Administradores, CREATOR OWNER. |
| `-ExpandirGrupos` | Resuelve los grupos a sus usuarios miembros, de forma recursiva. |
| `-CarpetaSalida` | Directorio donde escribir los CSV del informe. |
| `-Credencial` | Credenciales alternativas para conectarse al servidor. |

### Salida

Por consola se imprimen las dos tablas y, con `-CarpetaSalida`, se generan
`Permisos_Detalle_<servidor>_<fecha>.csv` y
`Permisos_PorUsuario_<servidor>_<fecha>.csv`. El detalle también se devuelve
por el pipeline, así que se puede filtrar al vuelo:

```powershell
.\Get-PermisosCarpetasCompartidas.ps1 -Servidor 10.10.1.65 -Profundidad 2 |
    Where-Object { $_.Permiso -eq 'Control total' -and $_.Origen -eq 'NTFS' }
```

Columnas del detalle: `Servidor`, `Recurso`, `Ruta`, `RutaLocal`, `Origen`
(`Compartido` o `NTFS`), `Identidad`, `EsGrupo`, `ViaGrupo` (grupo por el que
el usuario hereda el permiso), `Permiso`, `TipoAcceso` (`Allow` o `Deny`),
`Heredado` y `Propietario`.

### Cómo leer el resultado

El acceso real a una carpeta de red es la **intersección** del permiso de
compartición y el permiso NTFS, y las denegaciones (`Deny`) mandan sobre las
concesiones. Por eso el informe separa ambos orígenes en la columna `Origen`
en lugar de mostrar un único permiso "efectivo": un usuario con Control total
en NTFS pero solo Lectura en la compartición accede en modo lectura.

Con `-ExpandirGrupos`, cada miembro de un grupo aparece como fila propia y la
columna `ViaGrupo` indica por qué grupo le llega el permiso, que es lo que
suele hacer falta para responder "¿quién puede entrar aquí?".

### Pruebas

```powershell
pwsh -File .\Tests\Test-GetPermisosCarpetasCompartidas.ps1
```

Validan la sintaxis del script y sus funciones puras (traducción de máscaras
de permisos, normalización del servidor, filtros e informe). No requieren red
ni un servidor de archivos, así que corren en cualquier equipo.
