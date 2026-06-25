#!/usr/bin/env python3
"""Generate n8n importable workflow JSON files."""
import json
import uuid

GEMINI_PROMPT = (
    "Eres un asistente contable experto. Analiza este documento contable "
    "(factura, recibo, comprobante o similar). Si es escaneado, imagen o PDF "
    "sin texto seleccionable, aplica OCR. Extrae la informacion y responde "
    "EXCLUSIVAMENTE con un JSON valido sin markdown ni texto adicional, "
    "con esta estructura exacta:\n"
    '{"fecha_documento":"","tipo_documento":"","numero_documento":"",'
    '"proveedor":"","nit":"","subtotal":0,"iva":0,"retenciones":0,'
    '"total":0,"metodo_pago":"","banco":"","numero_comprobante":"",'
    '"concepto":"","observaciones":"","confianza":0}\n'
    "Usa formato fecha YYYY-MM-DD. Valores numericos como numeros. "
    "confianza es 0-100 indicando certeza de lectura."
)


def uid():
    return str(uuid.uuid4())


def node(name, ntype, position, parameters, type_version=1, credentials=None, on_error=None):
    n = {
        "parameters": parameters,
        "id": uid(),
        "name": name,
        "type": ntype,
        "typeVersion": type_version,
        "position": position,
    }
    if credentials:
        n["credentials"] = credentials
    if on_error:
        n["onError"] = on_error
    return n


def conn(source, target, source_output=0, target_input=0):
    return {
        "node": target,
        "type": "main",
        "index": target_input,
    }


def build_workflow1():
    cred_telegram = {"telegramApi": {"id": "TELEGRAM_CRED_ID", "name": "Telegram Bot Contabilidad"}}
    cred_mysql = {"mySql": {"id": "MYSQL_CRED_ID", "name": "MySQL Contabilidad"}}

    normalize_code = """
const msg = $input.first().json.message;
if (!msg) {
  return [{ json: { error: 'no_message', chat_id: null } }];
}

let fileId, mimeType, fileName;

if (msg.document) {
  fileId = msg.document.file_id;
  mimeType = msg.document.mime_type || 'application/octet-stream';
  fileName = msg.document.file_name || 'documento';
} else if (msg.photo && msg.photo.length) {
  const photo = msg.photo[msg.photo.length - 1];
  fileId = photo.file_id;
  mimeType = 'image/jpeg';
  fileName = 'foto.jpg';
} else {
  return [{ json: { error: 'no_file', chat_id: msg.chat.id } }];
}

const ext = (fileName.split('.').pop() || '').toLowerCase();
const allowed = ['jpg', 'jpeg', 'png', 'pdf'];
if (!allowed.includes(ext)) {
  return [{ json: { error: 'invalid_type', chat_id: msg.chat.id } }];
}

const mimeMap = {
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  png: 'image/png',
  pdf: 'application/pdf',
};

return [{
  json: {
    file_id: fileId,
    mime_type: mimeMap[ext] || mimeType,
    file_name: fileName,
    extension: ext,
    chat_id: msg.chat.id,
    usuario_telegram: msg.from?.username || String(msg.from?.id || ''),
    is_pdf: ext === 'pdf',
    is_image: ['jpg', 'jpeg', 'png'].includes(ext),
    docs_base_path: $env.DOCS_BASE_PATH || '/opt/documentos',
  },
}];
""".strip()

    prepare_gemini_code = f"""
const item = $input.first();
const binaryKey = Object.keys(item.binary || {{}})[0];
if (!binaryKey) {{
  throw new Error('No se pudo descargar el archivo desde Telegram');
}}

const buffer = await this.helpers.getBinaryDataBuffer(0, binaryKey);
const base64 = buffer.toString('base64');
const mime = item.json.mime_type;

const prompt = {json.dumps(GEMINI_PROMPT)};

const apiKey = $env.GEMINI_API_KEY;
if (!apiKey) {{
  throw new Error('GEMINI_API_KEY no configurada');
}}

return [{{
  json: {{
    ...item.json,
    gemini_url: `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${{apiKey}}`,
    gemini_body: {{
      contents: [{{
        parts: [
          {{ text: prompt }},
          {{ inline_data: {{ mime_type: mime, data: base64 }} }},
        ],
      }}],
      generationConfig: {{
        responseMimeType: 'application/json',
        temperature: 0.1,
      }},
    }},
  }},
  binary: item.binary,
}}];
""".strip()

    parse_gemini_code = """
const response = $input.first().json;
const meta = $('Normalizar Entrada').first().json;

let text = '';
try {
  text = response.candidates[0].content.parts[0].text;
} catch (e) {
  return [{ json: { parse_error: true, chat_id: meta.chat_id } }];
}

text = text.trim().replace(/^```json\\s*/i, '').replace(/```\\s*$/i, '');

let parsed;
try {
  parsed = JSON.parse(text);
} catch (e) {
  return [{ json: { parse_error: true, chat_id: meta.chat_id } }];
}

return [{
  json: {
    ...parsed,
    chat_id: meta.chat_id,
    usuario_telegram: meta.usuario_telegram,
    extension: meta.extension,
    file_name_original: meta.file_name,
    docs_base_path: meta.docs_base_path,
  },
}];
""".strip()

    build_path_code = """
const fs = require('fs');
const doc = $('Parsear Respuesta Gemini').first().json;
const now = new Date();
const year = now.getFullYear();
const month = String(now.getMonth() + 1).padStart(2, '0');
const uid = `${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
const basePath = doc.docs_base_path || '/opt/documentos';
const dir = `${basePath}/${year}/${month}`;
const fileName = `${uid}.${doc.extension}`;
const fullPath = `${dir}/${fileName}`;

fs.mkdirSync(dir, { recursive: true });

return [{
  json: {
    ...doc,
    nombre_archivo: fileName,
    ruta_archivo: fullPath,
    dir_path: dir,
  },
}];
""".strip()

    nodes = [
        node(
            "Telegram Trigger",
            "n8n-nodes-base.telegramTrigger",
            [-1200, 300],
            {"updates": ["message"]},
            1.1,
            cred_telegram,
        ),
        node(
            "Config Variables",
            "n8n-nodes-base.set",
            [-960, 300],
            {
                "mode": "manual",
                "duplicateItem": False,
                "assignments": {
                    "assignments": [
                        {
                            "id": uid(),
                            "name": "docs_base_path",
                            "value": "={{ $env.DOCS_BASE_PATH || '/opt/documentos' }}",
                            "type": "string",
                        },
                    ]
                },
                "includeOtherFields": True,
                "options": {},
            },
            3.4,
        ),
        node(
            "Normalizar Entrada",
            "n8n-nodes-base.code",
            [-720, 300],
            {"jsCode": normalize_code, "mode": "runOnceForAllItems"},
            2,
            on_error="continueErrorOutput",
        ),
        node(
            "Tiene Archivo Valido",
            "n8n-nodes-base.if",
            [-480, 300],
            {
                "conditions": {
                    "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                    "conditions": [
                        {
                            "id": uid(),
                            "leftValue": "={{ $json.error }}",
                            "rightValue": "",
                            "operator": {"type": "string", "operation": "empty", "singleValue": True},
                        }
                    ],
                    "combinator": "and",
                },
                "options": {},
            },
            2.2,
        ),
        node(
            "Telegram Archivo Invalido",
            "n8n-nodes-base.telegram",
            [-240, 520],
            {
                "resource": "message",
                "operation": "sendMessage",
                "chatId": "={{ $json.chat_id }}",
                "text": "Formato no soportado. Envie JPG, PNG, JPEG o PDF.",
                "additionalFields": {},
            },
            1.2,
            cred_telegram,
        ),
        node(
            "Descargar Archivo Telegram",
            "n8n-nodes-base.telegram",
            [-240, 160],
            {
                "resource": "file",
                "operation": "download",
                "fileId": "={{ $json.file_id }}",
            },
            1.2,
            cred_telegram,
            on_error="continueErrorOutput",
        ),
        node(
            "Preparar Gemini",
            "n8n-nodes-base.code",
            [0, 160],
            {"jsCode": prepare_gemini_code, "mode": "runOnceForAllItems"},
            2,
            on_error="continueErrorOutput",
        ),
        node(
            "Gemini Vision OCR",
            "n8n-nodes-base.httpRequest",
            [240, 160],
            {
                "method": "POST",
                "url": "={{ $json.gemini_url }}",
                "sendBody": True,
                "specifyBody": "json",
                "jsonBody": "={{ JSON.stringify($json.gemini_body) }}",
                "options": {"timeout": 120000},
            },
            4.2,
            on_error="continueErrorOutput",
        ),
        node(
            "Parsear Respuesta Gemini",
            "n8n-nodes-base.code",
            [480, 160],
            {"jsCode": parse_gemini_code, "mode": "runOnceForAllItems"},
            2,
            on_error="continueErrorOutput",
        ),
        node(
            "Documento Valido",
            "n8n-nodes-base.if",
            [720, 160],
            {
                "conditions": {
                    "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose"},
                    "conditions": [
                        {
                            "id": uid(),
                            "leftValue": "={{ $json.parse_error }}",
                            "rightValue": True,
                            "operator": {"type": "boolean", "operation": "notEquals"},
                        },
                        {
                            "id": uid(),
                            "leftValue": "={{ $json.fecha_documento }}",
                            "rightValue": "",
                            "operator": {"type": "string", "operation": "notEmpty", "singleValue": True},
                        },
                        {
                            "id": uid(),
                            "leftValue": "={{ $json.proveedor }}",
                            "rightValue": "",
                            "operator": {"type": "string", "operation": "notEmpty", "singleValue": True},
                        },
                        {
                            "id": uid(),
                            "leftValue": "={{ $json.total }}",
                            "rightValue": "",
                            "operator": {"type": "number", "operation": "exists", "singleValue": True},
                        },
                    ],
                    "combinator": "and",
                },
                "options": {},
            },
            2.2,
        ),
        node(
            "Telegram Lectura Fallida",
            "n8n-nodes-base.telegram",
            [960, 380],
            {
                "resource": "message",
                "operation": "sendMessage",
                "chatId": "={{ $json.chat_id }}",
                "text": "No fue posible leer correctamente el documento.",
                "additionalFields": {},
            },
            1.2,
            cred_telegram,
        ),
        node(
            "Verificar Duplicado MySQL",
            "n8n-nodes-base.mySql",
            [960, 80],
            {
                "operation": "executeQuery",
                "query": "SELECT id FROM documentos_contables WHERE numero_documento = ? AND proveedor = ? AND total = ? LIMIT 1;",
                "options": {
                    "queryReplacement": "={{ $('Parsear Respuesta Gemini').item.json.numero_documento }},={{ $('Parsear Respuesta Gemini').item.json.proveedor }},={{ $('Parsear Respuesta Gemini').item.json.total }}",
                },
            },
            2.4,
            cred_mysql,
            on_error="continueErrorOutput",
        ),
        node(
            "Es Duplicado",
            "n8n-nodes-base.if",
            [1200, 80],
            {
                "conditions": {
                    "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                    "conditions": [
                        {
                            "id": uid(),
                            "leftValue": "={{ $json.id }}",
                            "rightValue": "",
                            "operator": {"type": "number", "operation": "exists", "singleValue": True},
                        }
                    ],
                    "combinator": "and",
                },
                "options": {},
            },
            2.2,
        ),
        node(
            "Telegram Duplicado",
            "n8n-nodes-base.telegram",
            [1440, 280],
            {
                "resource": "message",
                "operation": "sendMessage",
                "chatId": "={{ $('Parsear Respuesta Gemini').item.json.chat_id }}",
                "text": "Documento ya registrado.",
                "additionalFields": {},
            },
            1.2,
            cred_telegram,
        ),
        node(
            "Construir Ruta Archivo",
            "n8n-nodes-base.code",
            [1440, -40],
            {"jsCode": build_path_code, "mode": "runOnceForAllItems"},
            2,
        ),
        node(
            "Restaurar Datos Documento",
            "n8n-nodes-base.code",
            [1680, -40],
            {
                "jsCode": """
const doc = $('Construir Ruta Archivo').first().json;
const binary = $('Descargar Archivo Telegram').first().binary;
return [{ json: doc, binary }];
""".strip(),
                "mode": "runOnceForAllItems",
            },
            2,
        ),
        node(
            "Guardar Archivo Original",
            "n8n-nodes-base.readWriteFile",
            [1920, -40],
            {
                "operation": "write",
                "fileName": "={{ $json.ruta_archivo }}",
                "dataPropertyName": "data",
                "options": {},
            },
            1,
            on_error="continueErrorOutput",
        ),
        node(
            "Mapear Insert MySQL",
            "n8n-nodes-base.set",
            [2160, -40],
            {
                "mode": "manual",
                "duplicateItem": False,
                "assignments": {
                    "assignments": [
                        {"id": uid(), "name": "fecha_documento", "value": "={{ $('Construir Ruta Archivo').item.json.fecha_documento }}", "type": "string"},
                        {"id": uid(), "name": "tipo_documento", "value": "={{ $('Construir Ruta Archivo').item.json.tipo_documento }}", "type": "string"},
                        {"id": uid(), "name": "numero_documento", "value": "={{ $('Construir Ruta Archivo').item.json.numero_documento }}", "type": "string"},
                        {"id": uid(), "name": "proveedor", "value": "={{ $('Construir Ruta Archivo').item.json.proveedor }}", "type": "string"},
                        {"id": uid(), "name": "nit", "value": "={{ $('Construir Ruta Archivo').item.json.nit }}", "type": "string"},
                        {"id": uid(), "name": "subtotal", "value": "={{ Number($('Construir Ruta Archivo').item.json.subtotal) || 0 }}", "type": "number"},
                        {"id": uid(), "name": "iva", "value": "={{ Number($('Construir Ruta Archivo').item.json.iva) || 0 }}", "type": "number"},
                        {"id": uid(), "name": "retenciones", "value": "={{ Number($('Construir Ruta Archivo').item.json.retenciones) || 0 }}", "type": "number"},
                        {"id": uid(), "name": "total", "value": "={{ Number($('Construir Ruta Archivo').item.json.total) || 0 }}", "type": "number"},
                        {"id": uid(), "name": "metodo_pago", "value": "={{ $('Construir Ruta Archivo').item.json.metodo_pago }}", "type": "string"},
                        {"id": uid(), "name": "banco", "value": "={{ $('Construir Ruta Archivo').item.json.banco }}", "type": "string"},
                        {"id": uid(), "name": "numero_comprobante", "value": "={{ $('Construir Ruta Archivo').item.json.numero_comprobante }}", "type": "string"},
                        {"id": uid(), "name": "concepto", "value": "={{ $('Construir Ruta Archivo').item.json.concepto }}", "type": "string"},
                        {"id": uid(), "name": "observaciones", "value": "={{ $('Construir Ruta Archivo').item.json.observaciones }}", "type": "string"},
                        {"id": uid(), "name": "nombre_archivo", "value": "={{ $('Construir Ruta Archivo').item.json.nombre_archivo }}", "type": "string"},
                        {"id": uid(), "name": "ruta_archivo", "value": "={{ $('Construir Ruta Archivo').item.json.ruta_archivo }}", "type": "string"},
                        {"id": uid(), "name": "usuario_telegram", "value": "={{ $('Construir Ruta Archivo').item.json.usuario_telegram }}", "type": "string"},
                    ]
                },
                "options": {},
            },
            3.4,
        ),
        node(
            "Insertar MySQL",
            "n8n-nodes-base.mySql",
            [2400, -40],
            {
                "operation": "insert",
                "table": "documentos_contables",
                "columns": "fecha_documento,tipo_documento,numero_documento,proveedor,nit,subtotal,iva,retenciones,total,metodo_pago,banco,numero_comprobante,concepto,observaciones,nombre_archivo,ruta_archivo,usuario_telegram",
                "options": {},
            },
            2.4,
            cred_mysql,
            on_error="continueErrorOutput",
        ),
        node(
            "Telegram Confirmacion",
            "n8n-nodes-base.telegram",
            [2640, -40],
            {
                "resource": "message",
                "operation": "sendMessage",
                "chatId": "={{ $('Parsear Respuesta Gemini').item.json.chat_id }}",
                "text": "=✅ Documento registrado\n\nProveedor: {{ $('Parsear Respuesta Gemini').item.json.proveedor }}\nFecha: {{ $('Parsear Respuesta Gemini').item.json.fecha_documento }}\nValor: {{ $('Parsear Respuesta Gemini').item.json.total }}",
                "additionalFields": {},
            },
            1.2,
            cred_telegram,
        ),
        node(
            "Telegram Error Proceso",
            "n8n-nodes-base.telegram",
            [960, 560],
            {
                "resource": "message",
                "operation": "sendMessage",
                "chatId": "={{ $('Normalizar Entrada').item.json.chat_id || $('Telegram Trigger').item.json.message.chat.id }}",
                "text": "Ocurrio un error procesando el documento. Intente nuevamente.",
                "additionalFields": {},
            },
            1.2,
            cred_telegram,
        ),
    ]

    connections = {
        "Telegram Trigger": {"main": [[conn("Telegram Trigger", "Config Variables")]]},
        "Config Variables": {"main": [[conn("Config Variables", "Normalizar Entrada")]]},
        "Normalizar Entrada": {
            "main": [
                [conn("Normalizar Entrada", "Tiene Archivo Valido")],
                [conn("Normalizar Entrada", "Telegram Error Proceso")],
            ]
        },
        "Tiene Archivo Valido": {
            "main": [
                [conn("Tiene Archivo Valido", "Descargar Archivo Telegram")],
                [conn("Tiene Archivo Valido", "Telegram Archivo Invalido")],
            ]
        },
        "Descargar Archivo Telegram": {
            "main": [
                [conn("Descargar Archivo Telegram", "Preparar Gemini")],
                [conn("Descargar Archivo Telegram", "Telegram Error Proceso")],
            ]
        },
        "Preparar Gemini": {
            "main": [
                [conn("Preparar Gemini", "Gemini Vision OCR")],
                [conn("Preparar Gemini", "Telegram Error Proceso")],
            ]
        },
        "Gemini Vision OCR": {
            "main": [
                [conn("Gemini Vision OCR", "Parsear Respuesta Gemini")],
                [conn("Gemini Vision OCR", "Telegram Error Proceso")],
            ]
        },
        "Parsear Respuesta Gemini": {
            "main": [
                [conn("Parsear Respuesta Gemini", "Documento Valido")],
                [conn("Parsear Respuesta Gemini", "Telegram Error Proceso")],
            ]
        },
        "Documento Valido": {
            "main": [
                [conn("Documento Valido", "Verificar Duplicado MySQL")],
                [conn("Documento Valido", "Telegram Lectura Fallida")],
            ]
        },
        "Verificar Duplicado MySQL": {
            "main": [
                [conn("Verificar Duplicado MySQL", "Es Duplicado")],
                [conn("Verificar Duplicado MySQL", "Telegram Error Proceso")],
            ]
        },
        "Es Duplicado": {
            "main": [
                [conn("Es Duplicado", "Telegram Duplicado")],
                [conn("Es Duplicado", "Construir Ruta Archivo")],
            ]
        },
        "Construir Ruta Archivo": {"main": [[conn("Construir Ruta Archivo", "Restaurar Datos Documento")]]},
        "Restaurar Datos Documento": {"main": [[conn("Restaurar Datos Documento", "Guardar Archivo Original")]]},
        "Guardar Archivo Original": {
            "main": [
                [conn("Guardar Archivo Original", "Mapear Insert MySQL")],
                [conn("Guardar Archivo Original", "Telegram Error Proceso")],
            ]
        },
        "Mapear Insert MySQL": {"main": [[conn("Mapear Insert MySQL", "Insertar MySQL")]]},
        "Insertar MySQL": {
            "main": [
                [conn("Insertar MySQL", "Telegram Confirmacion")],
                [conn("Insertar MySQL", "Telegram Error Proceso")],
            ]
        },
    }

    return {
        "name": "Asistente Contable - Recepcion Documentos Telegram",
        "nodes": nodes,
        "connections": connections,
        "active": False,
        "settings": {"executionOrder": "v1", "timezone": "America/Bogota"},
        "versionId": uid(),
        "meta": {"templateCredsSetupCompleted": False, "instanceId": uid()},
        "tags": [],
    }


def build_workflow2():
    cred_mysql = {"mySql": {"id": "MYSQL_CRED_ID", "name": "MySQL Contabilidad"}}
    cred_smtp = {"smtp": {"id": "SMTP_CRED_ID", "name": "SMTP Empresa"}}

    period_code = """
const now = new Date();
const firstDayThisMonth = new Date(now.getFullYear(), now.getMonth(), 1);
const lastDayPrevMonth = new Date(firstDayThisMonth.getTime() - 86400000);
const firstDayPrevMonth = new Date(lastDayPrevMonth.getFullYear(), lastDayPrevMonth.getMonth(), 1);

const fmt = (d) => d.toISOString().slice(0, 10);
const ym = `${lastDayPrevMonth.getFullYear()}_${String(lastDayPrevMonth.getMonth() + 1).padStart(2, '0')}`;

return [{
  json: {
    fecha_inicio: fmt(firstDayPrevMonth),
    fecha_fin: fmt(lastDayPrevMonth),
    periodo: ym,
    file_name: `Gastos_${ym}.xlsx`,
    report_email: $env.REPORT_EMAIL || 'correo@empresa.com',
    smtp_from: $env.SMTP_FROM || 'contabilidad@empresa.com',
  },
}];
""".strip()

    excel_code = """
const XLSX = require('xlsx');
const periodo = $('Calcular Periodo Anterior').first().json;
const docs = $('Consultar Documentos Mes Anterior').all().map(i => i.json);

let totalGastos = 0;
let totalIva = 0;
const porProveedor = {};
const porTipo = {};

for (const d of docs) {
  const total = Number(d.total) || 0;
  const iva = Number(d.iva) || 0;
  totalGastos += total;
  totalIva += iva;
  const prov = d.proveedor || 'Sin proveedor';
  const tipo = d.tipo_documento || 'Sin tipo';
  porProveedor[prov] = (porProveedor[prov] || 0) + total;
  porTipo[tipo] = (porTipo[tipo] || 0) + total;
}

const resumenRows = [
  ['Metrica', 'Valor'],
  ['Total Gastos', totalGastos],
  ['Total IVA', totalIva],
  ['', ''],
  ['Total por proveedor', ''],
];

for (const [k, v] of Object.entries(porProveedor).sort((a, b) => b[1] - a[1])) {
  resumenRows.push([k, v]);
}

resumenRows.push(['', '']);
resumenRows.push(['Total por tipo documento', '']);

for (const [k, v] of Object.entries(porTipo).sort((a, b) => b[1] - a[1])) {
  resumenRows.push([k, v]);
}

const item = $input.first();
const binaryKey = Object.keys(item.binary || {})[0];
if (!binaryKey) {
  throw new Error('No se genero el archivo consolidado');
}

const bufferIn = await this.helpers.getBinaryDataBuffer(0, binaryKey);
const wb = XLSX.read(bufferIn, { type: 'buffer' });
const ws2 = XLSX.utils.aoa_to_sheet(resumenRows);
XLSX.utils.book_append_sheet(wb, ws2, 'Resumen');
const bufferOut = XLSX.write(wb, { bookType: 'xlsx', type: 'buffer' });

return [{
  json: {
    file_name: periodo.file_name,
    report_email: periodo.report_email,
    smtp_from: periodo.smtp_from,
    periodo: periodo.periodo,
    total_registros: docs.length,
  },
  binary: {
    data: {
      data: bufferOut.toString('base64'),
      mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      fileName: periodo.file_name,
      fileExtension: 'xlsx',
    },
  },
}];
""".strip()

    nodes = [
        node(
            "Cron Mensual",
            "n8n-nodes-base.scheduleTrigger",
            [-800, 300],
            {
                "rule": {
                    "interval": [
                        {
                            "field": "cronExpression",
                            "expression": "0 6 1 * *",
                        }
                    ]
                }
            },
            1.2,
        ),
        node(
            "Calcular Periodo Anterior",
            "n8n-nodes-base.code",
            [-560, 300],
            {"jsCode": period_code, "mode": "runOnceForAllItems"},
            2,
        ),
        node(
            "Consultar Documentos Mes Anterior",
            "n8n-nodes-base.mySql",
            [-320, 300],
            {
                "operation": "executeQuery",
                "query": "SELECT fecha_documento, tipo_documento, numero_documento, proveedor, nit, concepto, subtotal, iva, retenciones, total, metodo_pago, banco FROM documentos_contables WHERE fecha_documento >= ? AND fecha_documento <= ? ORDER BY fecha_documento ASC;",
                "options": {
                    "queryReplacement": "={{ $('Calcular Periodo Anterior').item.json.fecha_inicio }},={{ $('Calcular Periodo Anterior').item.json.fecha_fin }}",
                },
            },
            2.4,
            cred_mysql,
            on_error="continueErrorOutput",
        ),
        node(
            "Hay Documentos",
            "n8n-nodes-base.if",
            [-80, 300],
            {
                "conditions": {
                    "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                    "conditions": [
                        {
                            "id": uid(),
                            "leftValue": "={{ $input.all().length }}",
                            "rightValue": 0,
                            "operator": {"type": "number", "operation": "gt"},
                        }
                    ],
                    "combinator": "and",
                },
                "options": {},
            },
            2.2,
        ),
        node(
            "Preparar Consolidado Spreadsheet",
            "n8n-nodes-base.set",
            [160, 180],
            {
                "mode": "manual",
                "duplicateItem": False,
                "includeOtherFields": False,
                "assignments": {
                    "assignments": [
                        {"id": uid(), "name": "Fecha", "value": "={{ $json.fecha_documento }}", "type": "string"},
                        {"id": uid(), "name": "Tipo Documento", "value": "={{ $json.tipo_documento }}", "type": "string"},
                        {"id": uid(), "name": "Numero Documento", "value": "={{ $json.numero_documento }}", "type": "string"},
                        {"id": uid(), "name": "Proveedor", "value": "={{ $json.proveedor }}", "type": "string"},
                        {"id": uid(), "name": "NIT", "value": "={{ $json.nit }}", "type": "string"},
                        {"id": uid(), "name": "Concepto", "value": "={{ $json.concepto }}", "type": "string"},
                        {"id": uid(), "name": "Subtotal", "value": "={{ Number($json.subtotal) || 0 }}", "type": "number"},
                        {"id": uid(), "name": "IVA", "value": "={{ Number($json.iva) || 0 }}", "type": "number"},
                        {"id": uid(), "name": "Retenciones", "value": "={{ Number($json.retenciones) || 0 }}", "type": "number"},
                        {"id": uid(), "name": "Total", "value": "={{ Number($json.total) || 0 }}", "type": "number"},
                        {"id": uid(), "name": "Metodo Pago", "value": "={{ $json.metodo_pago }}", "type": "string"},
                        {"id": uid(), "name": "Banco", "value": "={{ $json.banco }}", "type": "string"},
                    ]
                },
                "options": {},
            },
            3.4,
        ),
        node(
            "Spreadsheet Consolidado",
            "n8n-nodes-base.spreadsheetFile",
            [400, 180],
            {
                "operation": "toFile",
                "fileFormat": "xlsx",
                "options": {
                    "fileName": "={{ $('Calcular Periodo Anterior').item.json.file_name }}",
                    "sheetName": "Consolidado",
                },
            },
            2,
        ),
        node(
            "Agregar Hoja Resumen Excel",
            "n8n-nodes-base.code",
            [640, 180],
            {"jsCode": excel_code, "mode": "runOnceForAllItems"},
            2,
            on_error="continueErrorOutput",
        ),
        node(
            "Enviar Reporte SMTP",
            "n8n-nodes-base.emailSend",
            [880, 180],
            {
                "fromEmail": "={{ $json.smtp_from }}",
                "toEmail": "={{ $json.report_email }}",
                "subject": "Reporte Gastos Mes Anterior",
                "emailFormat": "text",
                "text": "=Adjunto reporte de gastos del periodo {{ $json.periodo }}.\nTotal registros: {{ $json.total_registros }}",
                "options": {
                    "attachments": "data",
                },
            },
            2.1,
            cred_smtp,
            on_error="continueErrorOutput",
        ),
        node(
            "Sin Documentos Email",
            "n8n-nodes-base.emailSend",
            [160, 460],
            {
                "fromEmail": "={{ $('Calcular Periodo Anterior').item.json.smtp_from }}",
                "toEmail": "={{ $('Calcular Periodo Anterior').item.json.report_email }}",
                "subject": "Reporte Gastos Mes Anterior",
                "emailFormat": "text",
                "text": "=No se encontraron documentos contables para el periodo {{ $('Calcular Periodo Anterior').item.json.periodo }}.",
                "options": {},
            },
            2.1,
            cred_smtp,
        ),
        node(
            "Error Reporte SMTP",
            "n8n-nodes-base.emailSend",
            [880, 420],
            {
                "fromEmail": "={{ $('Calcular Periodo Anterior').item.json.smtp_from }}",
                "toEmail": "={{ $('Calcular Periodo Anterior').item.json.report_email }}",
                "subject": "Error - Reporte Gastos Mes Anterior",
                "emailFormat": "text",
                "text": "Ocurrio un error generando el reporte mensual de gastos. Revise los logs de n8n.",
                "options": {},
            },
            2.1,
            cred_smtp,
        ),
    ]

    connections = {
        "Cron Mensual": {"main": [[conn("Cron Mensual", "Calcular Periodo Anterior")]]},
        "Calcular Periodo Anterior": {"main": [[conn("Calcular Periodo Anterior", "Consultar Documentos Mes Anterior")]]},
        "Consultar Documentos Mes Anterior": {
            "main": [
                [conn("Consultar Documentos Mes Anterior", "Hay Documentos")],
                [conn("Consultar Documentos Mes Anterior", "Error Reporte SMTP")],
            ]
        },
        "Hay Documentos": {
            "main": [
                [conn("Hay Documentos", "Preparar Consolidado Spreadsheet")],
                [conn("Hay Documentos", "Sin Documentos Email")],
            ]
        },
        "Preparar Consolidado Spreadsheet": {"main": [[conn("Preparar Consolidado Spreadsheet", "Spreadsheet Consolidado")]]},
        "Spreadsheet Consolidado": {"main": [[conn("Spreadsheet Consolidado", "Agregar Hoja Resumen Excel")]]},
        "Agregar Hoja Resumen Excel": {
            "main": [
                [conn("Agregar Hoja Resumen Excel", "Enviar Reporte SMTP")],
                [conn("Agregar Hoja Resumen Excel", "Error Reporte SMTP")],
            ]
        },
        "Enviar Reporte SMTP": {
            "main": [
                [],
                [conn("Enviar Reporte SMTP", "Error Reporte SMTP")],
            ]
        },
    }

    return {
        "name": "Asistente Contable - Reporte Mensual Gastos",
        "nodes": nodes,
        "connections": connections,
        "active": False,
        "settings": {"executionOrder": "v1", "timezone": "America/Bogota"},
        "versionId": uid(),
        "meta": {"templateCredsSetupCompleted": False, "instanceId": uid()},
        "tags": [],
    }


if __name__ == "__main__":
    w1 = build_workflow1()
    w2 = build_workflow2()

    with open("/workspace/n8n-workflows/workflow_facturas_telegram.json", "w", encoding="utf-8") as f:
        json.dump(w1, f, ensure_ascii=False, indent=2)

    with open("/workspace/n8n-workflows/workflow_reporte_mensual.json", "w", encoding="utf-8") as f:
        json.dump(w2, f, ensure_ascii=False, indent=2)

    json.load(open("/workspace/n8n-workflows/workflow_facturas_telegram.json"))
    json.load(open("/workspace/n8n-workflows/workflow_reporte_mensual.json"))
    print("OK", len(w1["nodes"]), len(w2["nodes"]))
