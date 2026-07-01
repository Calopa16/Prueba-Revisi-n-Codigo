<?php
set_time_limit(0);
ini_set('display_errors', 0);
ini_set('display_startup_errors', 0);
//error_reporting(E_ALL);

include '../includes/db.php';
include_once __DIR__ . '/../includes/usersTI.php';

$usuario      = $_SERVER['AUTH_USER'] ?? 'DESCONOCIDO';
$numeroSoltic = trim($_GET['numeroSoltic'] ?? '');

// FIX 1: la conexión se almacena en $connEros, no en $conn
$connEros = getConnection("panet");

$sql = "
SELECT TOP 1
     vgi.id                              AS entity_id
    ,vitt.PawSvcAuthGroups_id
    ,vitt.pawSvcAuthUsers_id
    ,vie.pawSvcAuthUsers_idCreatorSign   AS Signer_id
    ,FORMAT(DATEADD(HOUR, -5, GETUTCDATE()), 'yyyy-MM-ddTHH:mm:ss.fff') AS EscalationDate
    ,vitt.padIncidentsCode
    ,paw.username
    ,vgi.padOLAsUCs_id
    ,vgi.estimatedDateOLAUC
    ,vgi.pawSvcAuthUsers_idResponsible
FROM viewAllGlobalIncidents AS vgi
    LEFT JOIN viewAllIncidentsTimeTracking AS vitt ON vitt.padIncidentsCode = vgi.code
    LEFT JOIN PawSvcAuthUsers              paw     ON paw.id                = vitt.pawSvcAuthUsers_id
    LEFT JOIN viewAllIncidents             vie     ON vie.code              = vgi.code
WHERE
    vitt.PawSvcAuthGroupsName IS NOT NULL
    AND vitt.dedicatedHours   IS NOT NULL
    AND vitt.padIncidentsCode = ?
ORDER BY vitt.annotationDate DESC
";

// FIX 2: usar $connEros en lugar de $conn
$stmt = sqlsrv_query($connEros, $sql, [$numeroSoltic]);

if (!$stmt) {
    echo json_encode([
        'success' => false,
        'message' => 'Error consultando configuración.'
    ]);
    exit;
}

$row = sqlsrv_fetch_array($stmt, SQLSRV_FETCH_ASSOC);

if (!$row) {
    echo json_encode([
        'success' => false,
        'message' => 'Configuración no encontrada.'
    ]);
    exit;
}

// FIX 3: los campos del response deben corresponder a las columnas reales del SELECT
echo json_encode([
    'success' => true,
    'data'    => [
        'entityId'                  => $row['entity_id'],
        'pawSvcAuthGroupsId'        => $row['PawSvcAuthGroups_id'],
        'pawSvcAuthUsersId'         => $row['pawSvcAuthUsers_id'],
        'signerId'                  => $row['Signer_id'],
        'escalationDate'            => $row['EscalationDate'],
        'padIncidentsCode'          => $row['padIncidentsCode'],
        'username'                  => $row['username'],
        'padOLAsUCsId'              => $row['padOLAsUCs_id'],
        'estimatedDateOLAUC'        => $row['estimatedDateOLAUC'],
        'pawSvcAuthUsersIdResponsible' => $row['pawSvcAuthUsers_idResponsible'],
    ]
]);

// FIX 4: cerrar $connEros, no $conn
sqlsrv_close($connEros);
?>
