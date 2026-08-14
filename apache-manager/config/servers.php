<?php

/**
 * Server list configuration.
 *
 * Each entry is an associative array with the following keys:
 *
 *   name      (string) Human-readable label shown in the UI
 *   host      (string) IP address or hostname of the remote server
 *   port      (int)    SSH port — defaults to 22
 *   user      (string) SSH username
 *   auth      (string) Authentication method: 'password' or 'key'
 *
 * For auth = 'password':
 *   password  (string) SSH password
 *
 * For auth = 'key':
 *   key_path  (string) Absolute path to the private key file
 *   key_pass  (string) Passphrase for the private key (leave empty if none)
 *
 *   service   (string) systemd service name — defaults to 'apache2'
 *             Use 'httpd' for CentOS/RHEL-based systems.
 *
 * IMPORTANT: Keep this file outside the web root or restrict access to it.
 */

return [
    [
        'name'     => 'Web Server 01',
        'host'     => '192.168.1.10',
        'port'     => 22,
        'user'     => 'deploy',
        'auth'     => 'password',
        'password' => 'your-password-here',
        'service'  => 'apache2',
    ],
    [
        'name'     => 'Web Server 02',
        'host'     => '192.168.1.11',
        'port'     => 22,
        'user'     => 'deploy',
        'auth'     => 'key',
        'key_path' => '/home/www-data/.ssh/id_rsa',
        'key_pass' => '',
        'service'  => 'apache2',
    ],
    // Example for CentOS / RHEL (service name is 'httpd')
    // [
    //     'name'     => 'CentOS Server',
    //     'host'     => '10.0.0.5',
    //     'port'     => 22,
    //     'user'     => 'admin',
    //     'auth'     => 'password',
    //     'password' => 'your-password-here',
    //     'service'  => 'httpd',
    // ],
];
