<?php

/**
 * REST-style JSON API for Apache management.
 *
 * GET  /api.php?server=0&action=status   → get Apache status
 * POST /api.php                          → body: {"server":0,"action":"restart"}
 *
 * Actions: status | restart | start | stop
 *
 * Protect this endpoint with a token or IP whitelist in production.
 */

declare(strict_types=1);

require_once __DIR__ . '/../vendor/autoload.php';

use ApacheManager\ApacheManager;

header('Content-Type: application/json');

// ── Optional bearer-token auth ────────────────────────────────────────────────
// Uncomment and set API_TOKEN in your environment to enable:
//
// $expectedToken = getenv('API_TOKEN');
// $providedToken = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
// if ($expectedToken && $providedToken !== "Bearer {$expectedToken}") {
//     http_response_code(401);
//     echo json_encode(['error' => 'Unauthorized']);
//     exit;
// }

$servers = require __DIR__ . '/../config/servers.php';
$manager = new ApacheManager(timeout: 10);

// Parse input from GET or JSON body
if ($_SERVER['REQUEST_METHOD'] === 'GET') {
    $serverIdx = (int) ($_GET['server'] ?? -1);
    $action    = $_GET['action'] ?? 'status';
} else {
    $body      = json_decode(file_get_contents('php://input'), true) ?? [];
    $serverIdx = (int) ($body['server'] ?? -1);
    $action    = $body['action'] ?? 'status';
}

if (!isset($servers[$serverIdx])) {
    http_response_code(404);
    echo json_encode(['error' => 'Servidor no encontrado.']);
    exit;
}

$server = $servers[$serverIdx];

$result = match ($action) {
    'status'  => $manager->getStatus($server),
    'restart' => $manager->restart($server),
    'start'   => $manager->start($server),
    'stop'    => $manager->stop($server),
    default   => (function () use ($action) {
        http_response_code(400);
        return ['error' => "Acción desconocida: {$action}"];
    })(),
};

echo json_encode($result, JSON_PRETTY_PRINT);
