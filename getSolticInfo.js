const responseSoltic = await fetch(
    `api/getSolticInfo.php?numeroSoltic=${numeroSoltic}`
);

const solticResult = await responseSoltic.json();

if (!solticResult.success) {
    console.error('Error:', solticResult.message);
    return;
}

const {
    entityId,
    pawSvcAuthGroupsId,
    pawSvcAuthUsersId,
    signerId,
    escalationDate,
    padIncidentsCode,
    username,
    padOLAsUCsId,
    estimatedDateOLAUC,
    pawSvcAuthUsersIdResponsible,
} = solticResult.data;
