# Apache Manager — PHP

Panel web y API en PHP para **monitorear y controlar Apache** en múltiples servidores remotos a través de SSH.

## Funcionalidades

| Acción | Descripción |
|--------|-------------|
| **Estado** | Consulta si Apache está activo, inactivo o en fallo |
| **Reiniciar** | Ejecuta `systemctl restart apache2` |
| **Iniciar** | Ejecuta `systemctl start apache2` |
| **Detener** | Ejecuta `systemctl stop apache2` |

La conexión SSH usa [phpseclib](https://phpseclib.com/) — **no requiere extensiones** de PHP adicionales (sin `ssh2.so`).

---

## Estructura

```
apache-manager/
├── composer.json
├── config/
│   ├── servers.php      ← lista de servidores
│   └── .htaccess        ← bloquea acceso web a la config
├── public/
│   ├── index.php        ← panel web
│   └── api.php          ← API JSON REST
└── src/
    └── ApacheManager.php
```

---

## Instalación

```bash
cd apache-manager
composer install
```

Apunta el `DocumentRoot` de Apache/Nginx a la carpeta `public/`.

---

## Configuración de servidores

Edita `config/servers.php`. Cada servidor es un array con las siguientes claves:

```php
[
    'name'     => 'Mi servidor',   // Etiqueta visible en el panel
    'host'     => '192.168.1.10', // IP o hostname
    'port'     => 22,              // Puerto SSH (defecto 22)
    'user'     => 'deploy',        // Usuario SSH
    'auth'     => 'password',      // 'password' o 'key'
    'password' => 'secreto',       // Si auth = 'password'
    'service'  => 'apache2',       // 'apache2' (Debian/Ubuntu) o 'httpd' (CentOS/RHEL)
]
```

### Autenticación por llave SSH

```php
[
    'name'     => 'Servidor prod',
    'host'     => '10.0.0.1',
    'user'     => 'admin',
    'auth'     => 'key',
    'key_path' => '/home/www-data/.ssh/id_rsa',
    'key_pass' => '',              // Passphrase (vacío si no tiene)
    'service'  => 'apache2',
]
```

---

## Panel Web

Abre `http://tu-servidor/` en el navegador.

- La página carga automáticamente el estado de todos los servidores al abrirse.
- El botón **↻ Actualizar todos** refresca el estado de forma escalonada.
- Cada tarjeta tiene botones para **Estado**, **Reiniciar**, **Iniciar** y **Detener**.

---

## API JSON

### Consultar estado
```bash
curl "http://tu-servidor/api.php?server=0&action=status"
```

### Reiniciar Apache
```bash
curl -X POST http://tu-servidor/api.php \
     -H "Content-Type: application/json" \
     -d '{"server": 0, "action": "restart"}'
```

### Respuesta de estado
```json
{
    "running": true,
    "status": "active",
    "output": "● apache2.service - The Apache HTTP Server\n   Loaded: ...",
    "error": null
}
```

### Respuesta de acción (restart/start/stop)
```json
{
    "success": true,
    "output": "",
    "error": null
}
```

---

## Uso del servicio desde PHP (modo librería)

```php
require 'vendor/autoload.php';

use ApacheManager\ApacheManager;

$manager = new ApacheManager(timeout: 10);

$server = [
    'name'     => 'Web 01',
    'host'     => '192.168.1.10',
    'port'     => 22,
    'user'     => 'deploy',
    'auth'     => 'password',
    'password' => 'mi-clave',
    'service'  => 'apache2',
];

// Verificar estado
$status = $manager->getStatus($server);
if ($status['running']) {
    echo "Apache está ACTIVO\n";
} else {
    echo "Apache está {$status['status']}\n";
}

// Reiniciar si está caído
if (!$status['running']) {
    $result = $manager->restart($server);
    echo $result['success'] ? "Reiniciado OK\n" : "Error: {$result['error']}\n";
}
```

---

## Requisitos del servidor remoto

El usuario SSH debe poder ejecutar `systemctl` con `sudo` sin contraseña. Agrega esto en `/etc/sudoers` del servidor remoto:

```
deploy ALL=(ALL) NOPASSWD: /bin/systemctl start apache2, /bin/systemctl stop apache2, /bin/systemctl restart apache2
```

---

## Seguridad

- **Nunca** expongas `config/servers.php` en la web (el `.htaccess` incluido lo bloquea para Apache).
- Usa autenticación por llave SSH en producción.
- Restringe el acceso al panel con autenticación HTTP o whitelist de IPs.
- Para la API, descomenta el bloque de bearer-token en `api.php`.
