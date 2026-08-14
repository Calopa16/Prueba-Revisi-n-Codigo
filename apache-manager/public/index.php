<?php

declare(strict_types=1);

require_once __DIR__ . '/../vendor/autoload.php';

use ApacheManager\ApacheManager;

$servers = require __DIR__ . '/../config/servers.php';
$manager = new ApacheManager(timeout: 10);

// ── Handle AJAX / form actions ───────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    header('Content-Type: application/json');

    $action    = $_POST['action']    ?? '';
    $serverIdx = (int) ($_POST['server'] ?? -1);

    if (!isset($servers[$serverIdx])) {
        echo json_encode(['error' => 'Servidor no encontrado.']);
        exit;
    }

    $server = $servers[$serverIdx];

    $result = match ($action) {
        'status'  => $manager->getStatus($server),
        'restart' => $manager->restart($server),
        'start'   => $manager->start($server),
        'stop'    => $manager->stop($server),
        default   => ['error' => "Acción desconocida: {$action}"],
    };

    echo json_encode($result);
    exit;
}

// ── Render page ───────────────────────────────────────────────────────────────
$totalServers = count($servers);
?>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Apache Manager</title>
    <style>
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

        :root {
            --bg:        #0f1117;
            --surface:   #1a1d27;
            --border:    #2a2d3e;
            --accent:    #4f6ef7;
            --green:     #22c55e;
            --red:       #ef4444;
            --yellow:    #eab308;
            --text:      #e2e8f0;
            --muted:     #64748b;
            --radius:    12px;
            --font:      'Segoe UI', system-ui, -apple-system, sans-serif;
        }

        body {
            background: var(--bg);
            color: var(--text);
            font-family: var(--font);
            min-height: 100vh;
            padding: 2rem 1rem;
        }

        header {
            max-width: 960px;
            margin: 0 auto 2rem;
            display: flex;
            align-items: center;
            gap: 1rem;
        }

        header .logo {
            font-size: 2rem;
        }

        header h1 {
            font-size: 1.5rem;
            font-weight: 700;
            letter-spacing: -.02em;
        }

        header p {
            font-size: .85rem;
            color: var(--muted);
        }

        .summary-bar {
            max-width: 960px;
            margin: 0 auto 1.5rem;
            display: flex;
            gap: .75rem;
            flex-wrap: wrap;
        }

        .summary-chip {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 999px;
            padding: .3rem .85rem;
            font-size: .8rem;
            color: var(--muted);
        }

        .summary-chip strong { color: var(--text); }

        .grid {
            max-width: 960px;
            margin: 0 auto;
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
            gap: 1.25rem;
        }

        .card {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: var(--radius);
            padding: 1.25rem;
            display: flex;
            flex-direction: column;
            gap: 1rem;
            transition: border-color .2s;
        }

        .card:hover { border-color: var(--accent); }

        .card-header {
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
        }

        .card-title {
            font-weight: 600;
            font-size: 1rem;
        }

        .card-meta {
            font-size: .75rem;
            color: var(--muted);
            margin-top: .15rem;
        }

        .badge {
            display: inline-flex;
            align-items: center;
            gap: .35rem;
            font-size: .75rem;
            font-weight: 600;
            padding: .25rem .65rem;
            border-radius: 999px;
            white-space: nowrap;
        }

        .badge.loading { background: rgba(100,116,139,.15); color: var(--muted); }
        .badge.active  { background: rgba(34,197,94,.15);   color: var(--green); }
        .badge.inactive,
        .badge.failed  { background: rgba(239,68,68,.15);   color: var(--red); }
        .badge.unknown { background: rgba(234,179,8,.15);   color: var(--yellow); }

        .dot {
            width: 7px; height: 7px;
            border-radius: 50%;
            background: currentColor;
            display: inline-block;
        }

        .dot.pulse {
            animation: pulse 1.4s ease-in-out infinite;
        }

        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50%       { opacity: .3; }
        }

        .actions {
            display: flex;
            gap: .5rem;
            flex-wrap: wrap;
        }

        .btn {
            flex: 1;
            padding: .5rem .75rem;
            border: none;
            border-radius: 8px;
            font-size: .8rem;
            font-weight: 600;
            cursor: pointer;
            transition: opacity .15s, transform .1s;
            min-width: 70px;
        }

        .btn:hover   { opacity: .85; }
        .btn:active  { transform: scale(.97); }
        .btn:disabled{ opacity: .4; cursor: not-allowed; }

        .btn-status  { background: rgba(79,110,247,.2);  color: #7b95ff; }
        .btn-restart { background: rgba(234,179,8,.2);   color: #f0c430; }
        .btn-start   { background: rgba(34,197,94,.2);   color: #4ade80; }
        .btn-stop    { background: rgba(239,68,68,.2);   color: #f87171; }

        .output-box {
            background: #0a0c14;
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: .75rem;
            font-family: 'Courier New', monospace;
            font-size: .72rem;
            color: #a0aec0;
            white-space: pre-wrap;
            word-break: break-all;
            max-height: 180px;
            overflow-y: auto;
            display: none;
        }

        .output-box.visible { display: block; }

        .spinner {
            display: inline-block;
            width: 12px; height: 12px;
            border: 2px solid currentColor;
            border-top-color: transparent;
            border-radius: 50%;
            animation: spin .6s linear infinite;
            vertical-align: middle;
        }

        @keyframes spin { to { transform: rotate(360deg); } }

        footer {
            max-width: 960px;
            margin: 2.5rem auto 0;
            text-align: center;
            font-size: .75rem;
            color: var(--muted);
        }

        .refresh-all-btn {
            background: rgba(79,110,247,.15);
            color: var(--accent);
            border: 1px solid rgba(79,110,247,.3);
            border-radius: 8px;
            padding: .45rem 1rem;
            font-size: .8rem;
            font-weight: 600;
            cursor: pointer;
            transition: background .2s;
            margin-left: auto;
        }

        .refresh-all-btn:hover { background: rgba(79,110,247,.3); }
    </style>
</head>
<body>

<header>
    <span class="logo">🛡️</span>
    <div>
        <h1>Apache Manager</h1>
        <p>Monitoreo y control de Apache en servidores remotos vía SSH</p>
    </div>
    <button class="refresh-all-btn" onclick="refreshAll()">↻ Actualizar todos</button>
</header>

<div class="summary-bar">
    <span class="summary-chip">Servidores configurados: <strong><?= $totalServers ?></strong></span>
    <span class="summary-chip" id="chip-active">Activos: <strong id="count-active">—</strong></span>
    <span class="summary-chip" id="chip-inactive">Inactivos: <strong id="count-inactive">—</strong></span>
</div>

<div class="grid" id="server-grid">
<?php foreach ($servers as $idx => $server): ?>
    <div class="card" id="card-<?= $idx ?>">
        <div class="card-header">
            <div>
                <div class="card-title"><?= htmlspecialchars($server['name']) ?></div>
                <div class="card-meta">
                    <?= htmlspecialchars($server['host']) ?>:<?= (int)($server['port'] ?? 22) ?>
                    &nbsp;·&nbsp;
                    servicio: <code><?= htmlspecialchars($server['service'] ?? 'apache2') ?></code>
                </div>
            </div>
            <span class="badge loading" id="badge-<?= $idx ?>">
                <span class="dot pulse"></span> —
            </span>
        </div>

        <div class="actions">
            <button class="btn btn-status"  onclick="doAction(<?= $idx ?>, 'status')">Estado</button>
            <button class="btn btn-restart" onclick="doAction(<?= $idx ?>, 'restart')">Reiniciar</button>
            <button class="btn btn-start"   onclick="doAction(<?= $idx ?>, 'start')">Iniciar</button>
            <button class="btn btn-stop"    onclick="doAction(<?= $idx ?>, 'stop')">Detener</button>
        </div>

        <pre class="output-box" id="output-<?= $idx ?>"></pre>
    </div>
<?php endforeach; ?>
</div>

<footer>
    Apache Manager &mdash; conexión vía SSH usando phpseclib &mdash; <?= date('Y') ?>
</footer>

<script>
const CARDS = <?= $totalServers ?>;

async function doAction(idx, action) {
    const badge   = document.getElementById(`badge-${idx}`);
    const output  = document.getElementById(`output-${idx}`);
    const buttons = document.querySelectorAll(`#card-${idx} .btn`);

    buttons.forEach(b => b.disabled = true);
    badge.className = 'badge loading';
    badge.innerHTML = '<span class="spinner"></span> Procesando…';

    try {
        const fd = new FormData();
        fd.append('action', action);
        fd.append('server', idx);

        const res  = await fetch('', { method: 'POST', body: fd });
        const data = await res.json();

        renderResult(idx, action, data);
    } catch (e) {
        setBadge(idx, 'unknown', '⚠ Error de red');
        showOutput(idx, 'Error de comunicación con el servidor: ' + e.message);
    } finally {
        buttons.forEach(b => b.disabled = false);
    }

    updateCounters();
}

function renderResult(idx, action, data) {
    if (data.error && !data.running !== undefined) {
        setBadge(idx, 'unknown', '⚠ Error');
        showOutput(idx, '❌ ' + data.error + (data.output ? '\n\n' + data.output : ''));
        return;
    }

    if (action === 'status') {
        const status = data.status ?? 'unknown';
        const label  = statusLabel(status);
        setBadge(idx, status, label);
        showOutput(idx, data.error ? '❌ ' + data.error : (data.output || '(sin salida)'));
        return;
    }

    // restart / start / stop
    if (data.success) {
        const actionLabel = { restart: 'Reiniciado', start: 'Iniciado', stop: 'Detenido' }[action] ?? 'OK';
        const newStatus   = action === 'stop' ? 'inactive' : 'active';
        setBadge(idx, newStatus, statusLabel(newStatus));
        showOutput(idx, `✅ ${actionLabel} correctamente.\n` + (data.output || ''));
    } else {
        setBadge(idx, 'failed', '✗ Falló');
        showOutput(idx, '❌ ' + (data.error ?? 'Error desconocido') + '\n' + (data.output || ''));
    }
}

function statusLabel(status) {
    return {
        active:   '● Activo',
        inactive: '○ Inactivo',
        failed:   '✗ Fallido',
        unknown:  '? Desconocido',
    }[status] ?? status;
}

function setBadge(idx, statusClass, text) {
    const badge = document.getElementById(`badge-${idx}`);
    badge.className = `badge ${statusClass}`;
    badge.innerHTML = `<span class="dot"></span> ${text}`;
}

function showOutput(idx, text) {
    const box = document.getElementById(`output-${idx}`);
    box.textContent = text.trim();
    box.classList.add('visible');
}

function updateCounters() {
    let active = 0, inactive = 0;
    document.querySelectorAll('.badge').forEach(b => {
        if (b.classList.contains('active'))   active++;
        if (b.classList.contains('inactive') || b.classList.contains('failed')) inactive++;
    });
    document.getElementById('count-active').textContent   = active;
    document.getElementById('count-inactive').textContent = inactive;
}

function refreshAll() {
    for (let i = 0; i < CARDS; i++) {
        setTimeout(() => doAction(i, 'status'), i * 400);
    }
}

// Auto-load status on page load
window.addEventListener('DOMContentLoaded', refreshAll);
</script>
</body>
</html>
