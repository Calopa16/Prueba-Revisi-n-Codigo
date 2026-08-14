<?php

declare(strict_types=1);

namespace ApacheManager;

use phpseclib3\Net\SSH2;
use phpseclib3\Crypt\PublicKeyLoader;

class ApacheManager
{
    private int $timeout;

    public function __construct(int $timeout = 10)
    {
        $this->timeout = $timeout;
    }

    /**
     * Connect to a remote server via SSH using password authentication.
     */
    private function connectWithPassword(string $host, int $port, string $user, string $password): SSH2
    {
        $ssh = new SSH2($host, $port, $this->timeout);

        if (!$ssh->login($user, $password)) {
            throw new \RuntimeException("SSH authentication failed for {$user}@{$host}:{$port}");
        }

        return $ssh;
    }

    /**
     * Connect to a remote server via SSH using private key authentication.
     */
    private function connectWithKey(string $host, int $port, string $user, string $privateKeyPath, string $passphrase = ''): SSH2
    {
        if (!file_exists($privateKeyPath)) {
            throw new \RuntimeException("Private key not found: {$privateKeyPath}");
        }

        $key = PublicKeyLoader::load(file_get_contents($privateKeyPath), $passphrase !== '' ? $passphrase : false);
        $ssh = new SSH2($host, $port, $this->timeout);

        if (!$ssh->login($user, $key)) {
            throw new \RuntimeException("SSH key authentication failed for {$user}@{$host}:{$port}");
        }

        return $ssh;
    }

    /**
     * Get the Apache service status on a remote server.
     *
     * Returns an array with:
     *   - running (bool)
     *   - status  (string) 'active', 'inactive', 'failed', 'unknown'
     *   - output  (string) raw command output
     *   - error   (string|null) error message if connection/command failed
     */
    public function getStatus(array $server): array
    {
        try {
            $ssh = $this->buildConnection($server);
            $serviceName = $server['service'] ?? 'apache2';

            // is-active returns a single word: active / inactive / failed / unknown
            $active = trim((string) $ssh->exec("systemctl is-active {$serviceName} 2>/dev/null || echo unknown"));

            // Full human-readable status (trimmed to avoid huge output)
            $output = (string) $ssh->exec("systemctl status {$serviceName} --no-pager --lines=20 2>&1");

            $ssh->disconnect();

            return [
                'running' => $active === 'active',
                'status'  => $active,
                'output'  => $output,
                'error'   => null,
            ];
        } catch (\Throwable $e) {
            return [
                'running' => false,
                'status'  => 'unknown',
                'output'  => '',
                'error'   => $e->getMessage(),
            ];
        }
    }

    /**
     * Restart Apache on a remote server.
     *
     * Returns an array with:
     *   - success (bool)
     *   - output  (string) command output
     *   - error   (string|null) error message if connection/command failed
     */
    public function restart(array $server): array
    {
        try {
            $ssh = $this->buildConnection($server);
            $serviceName = $server['service'] ?? 'apache2';

            $output = (string) $ssh->exec("sudo systemctl restart {$serviceName} 2>&1; echo EXIT:$?");

            $ssh->disconnect();

            $success = str_contains($output, 'EXIT:0');

            return [
                'success' => $success,
                'output'  => trim(str_replace('EXIT:0', '', $output)),
                'error'   => $success ? null : 'Restart command returned a non-zero exit code.',
            ];
        } catch (\Throwable $e) {
            return [
                'success' => false,
                'output'  => '',
                'error'   => $e->getMessage(),
            ];
        }
    }

    /**
     * Stop Apache on a remote server.
     */
    public function stop(array $server): array
    {
        try {
            $ssh = $this->buildConnection($server);
            $serviceName = $server['service'] ?? 'apache2';

            $output = (string) $ssh->exec("sudo systemctl stop {$serviceName} 2>&1; echo EXIT:$?");

            $ssh->disconnect();

            $success = str_contains($output, 'EXIT:0');

            return [
                'success' => $success,
                'output'  => trim(str_replace('EXIT:0', '', $output)),
                'error'   => $success ? null : 'Stop command returned a non-zero exit code.',
            ];
        } catch (\Throwable $e) {
            return [
                'success' => false,
                'output'  => '',
                'error'   => $e->getMessage(),
            ];
        }
    }

    /**
     * Start Apache on a remote server.
     */
    public function start(array $server): array
    {
        try {
            $ssh = $this->buildConnection($server);
            $serviceName = $server['service'] ?? 'apache2';

            $output = (string) $ssh->exec("sudo systemctl start {$serviceName} 2>&1; echo EXIT:$?");

            $ssh->disconnect();

            $success = str_contains($output, 'EXIT:0');

            return [
                'success' => $success,
                'output'  => trim(str_replace('EXIT:0', '', $output)),
                'error'   => $success ? null : 'Start command returned a non-zero exit code.',
            ];
        } catch (\Throwable $e) {
            return [
                'success' => false,
                'output'  => '',
                'error'   => $e->getMessage(),
            ];
        }
    }

    /**
     * Build an SSH2 connection from a server config array.
     *
     * Server config keys:
     *   host         (string) IP or hostname — required
     *   port         (int)    SSH port — default 22
     *   user         (string) SSH user — required
     *   auth         (string) 'password' | 'key' — default 'password'
     *   password     (string) password (when auth = 'password')
     *   key_path     (string) path to private key file (when auth = 'key')
     *   key_pass     (string) passphrase for private key — optional
     *   service      (string) systemd service name — default 'apache2'
     */
    private function buildConnection(array $server): SSH2
    {
        $host = $server['host'] ?? throw new \InvalidArgumentException('Server "host" is required.');
        $port = (int) ($server['port'] ?? 22);
        $user = $server['user'] ?? throw new \InvalidArgumentException('Server "user" is required.');
        $auth = $server['auth'] ?? 'password';

        if ($auth === 'key') {
            return $this->connectWithKey(
                $host,
                $port,
                $user,
                $server['key_path'] ?? throw new \InvalidArgumentException('Server "key_path" is required when auth=key.'),
                $server['key_pass'] ?? ''
            );
        }

        return $this->connectWithPassword(
            $host,
            $port,
            $user,
            $server['password'] ?? throw new \InvalidArgumentException('Server "password" is required when auth=password.')
        );
    }
}
