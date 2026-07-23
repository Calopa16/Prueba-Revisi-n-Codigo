#!/usr/bin/env python3
import json, uuid

def uid():
    return str(uuid.uuid4())

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

def c(node):
    return {"node": node, "type": "main", "index": 0}

def build():
    TC = {"telegramApi": {"id": "TELEGRAM_CRED_ID", "name": "Telegram Bot Contabilidad"}}
    MC = {"mySql":      {"id": "MYSQL_CRED_ID",    "name": "MySQL Contabilidad"}}

    normalize_code = r"""
const msg = $input.first().json.message;
if (!msg) return [{ json: { error: 'no_message', chat_id: null } }];

let fileId, mimeType, fileName;
if (msg.document) {
  fileId   = msg.document.file_id;
  mimeType = msg.document.mime_type || 'application/octet-stream';
  fileName = msg.document.file_name || 'documento';
} else if (msg.photo && msg.photo.length) {
  const photo = msg.photo[msg.photo.length - 1];
  fileId   = photo.file_id;
  mimeType = 'image/jpeg';
  fileName = 'foto.jpg';
} else {
  return [{ json: { error: 'no_file', chat_id: msg.chat.id } }];
}

const ext = (fileName.split('.').pop() || '').toLowerCase();
if (!['jpg','jpeg','png','pdf'].includes(ext))
  return [{ json: { error: 'invalid_type', chat_id: msg.chat.id } }];

const mimeMap = { jpg:'image/jpeg', jpeg:'image/jpeg', png:'image/png', pdf:'application/pdf' };

return [{ json: {
  file_id: fileId,
  mime_type: mimeMap[ext] || mimeType,
  file_name: fileName,
  extension: ext,
  chat_id: msg.chat.id,
  usuario_telegram: msg.from?.username || String(msg.from?.id || ''),
  is_pdf:  ext === 'pdf',
  is_image: ['jpg','jpeg','png'].includes(ext),
  docs_base_path: '/opt/documentos',
}}];
""".strip()

    prepare_gemini_code = (
        "const binaryKey = Object.keys($input.first().binary || {})[0];\n"
        "if (!binaryKey) throw new Error('Sin binario del archivo');\n\n"
        "const buffer = await this.helpers.getBinaryDataBuffer(0, binaryKey);\n"
        "const base64 = buffer.toString('base64');\n"
        "const meta   = $('Normalizar Entrada').first().json;\n"
        "const mime   = meta.mime_type;\n\n"
        "const prompt = " + json.dumps(GEMINI_PROMPT) + ";\n\n"
        "const apiKey = $vars.GEMINI_API_KEY;\n"
        "if (!apiKey) throw new Error('Variable GEMINI_API_KEY no configurada en n8n');\n\n"
        "return [{\n"
        "  json: {\n"
        "    ...meta,\n"
        "    gemini_url: `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${apiKey}`,\n"
        "    gemini_body: {\n"
        "      contents: [{ parts: [\n"
        "        { text: prompt },\n"
        "        { inline_data: { mime_type: mime, data: base64 } },\n"
        "      ]}],\n"
        "      generationConfig: { responseMimeType: 'application/json', temperature: 0.1 },\n"
        "    },\n"
        "  },\n"
        "  binary: $input.first().binary,\n"
        "}];"
    )

    parse_gemini_code = r"""
const response = $input.first().json;
const meta     = $('Normalizar Entrada').first().json;

let text = '';
try { text = response.candidates[0].content.parts[0].text; }
catch(e) { return [{ json: { parse_error: true, chat_id: meta.chat_id } }]; }

text = text.trim().replace(/^```json\s*/i,'').replace(/```\s*$/i,'');

let parsed;
try { parsed = JSON.parse(text); }
catch(e) { return [{ json: { parse_error: true, chat_id: meta.chat_id } }]; }

return [{ json: {
  ...parsed,
  chat_id:          meta.chat_id,
  usuario_telegram: meta.usuario_telegram,
  extension:        meta.extension,
  file_name_original: meta.file_name,
  docs_base_path:   meta.docs_base_path,
}}];
""".strip()

    build_path_code = r"""
const fs  = require('fs');
const doc = $('Parsear Respuesta Gemini').first().json;
const now = new Date();
const year  = now.getFullYear();
const month = String(now.getMonth()+1).padStart(2,'0');
const uid   = `${Date.now()}_${Math.random().toString(36).slice(2,10)}`;
const base  = doc.docs_base_path || '/opt/documentos';
const dir   = `${base}/${year}/${month}`;
const name  = `${uid}.${doc.extension}`;
const path  = `${dir}/${name}`;
fs.mkdirSync(dir, { recursive: true });
return [{ json: { ...doc, nombre_archivo: name, ruta_archivo: path, dir_path: dir } }];
""".strip()

    restaurar_code = (
        "const doc    = $('Construir Ruta Archivo').first().json;\n"
        "const binary = $('Descargar Archivo Binario').first().binary;\n"
        "return [{ json: doc, binary }];"
    )

    nodes = [
        # 1
        {"parameters":{"updates":["message"]},
         "id":uid(),"name":"Telegram Trigger","type":"n8n-nodes-base.telegramTrigger",
         "typeVersion":1.1,"position":[-1200,300],"credentials":TC},
        # 2
        {"parameters":{
            "mode":"manual","duplicateItem":False,
            "assignments":{"assignments":[{"id":uid(),"name":"docs_base_path","value":"/opt/documentos","type":"string"}]},
            "includeOtherFields":True,"options":{}},
         "id":uid(),"name":"Config Variables","type":"n8n-nodes-base.set",
         "typeVersion":3.4,"position":[-960,300]},
        # 3
        {"parameters":{"jsCode":normalize_code,"mode":"runOnceForAllItems"},
         "id":uid(),"name":"Normalizar Entrada","type":"n8n-nodes-base.code",
         "typeVersion":2,"position":[-720,300],"onError":"continueErrorOutput"},
        # 4
        {"parameters":{
            "conditions":{"options":{"caseSensitive":True,"leftValue":"","typeValidation":"strict"},
            "conditions":[{"id":uid(),"leftValue":"={{ $json.error }}","rightValue":"",
                "operator":{"type":"string","operation":"empty","singleValue":True}}],
            "combinator":"and"},"options":{}},
         "id":uid(),"name":"Tiene Archivo Valido","type":"n8n-nodes-base.if",
         "typeVersion":2.2,"position":[-480,300]},
        # 5 - falso branch
        {"parameters":{"resource":"message","operation":"sendMessage",
            "chatId":"={{ $json.chat_id }}",
            "text":"Formato no soportado. Envie JPG, PNG, JPEG o PDF.","additionalFields":{}},
         "id":uid(),"name":"Telegram Archivo Invalido","type":"n8n-nodes-base.telegram",
         "typeVersion":1.2,"position":[-240,520],"credentials":TC},
        # 6 - NUEVO: obtener ruta del archivo
        {"parameters":{
            "method":"GET",
            "url":"=https://api.telegram.org/bot{{ $vars.TELEGRAM_TOKEN }}/getFile",
            "sendQuery":True,
            "queryParameters":{"parameters":[{
                "name":"file_id",
                "value":"={{ $('Normalizar Entrada').item.json.file_id }}"}]},
            "options":{}},
         "id":uid(),"name":"Obtener Info Archivo","type":"n8n-nodes-base.httpRequest",
         "typeVersion":4.2,"position":[-240,160],"onError":"continueErrorOutput"},
        # 7 - NUEVO: descargar binario
        {"parameters":{
            "method":"GET",
            "url":"=https://api.telegram.org/file/bot{{ $vars.TELEGRAM_TOKEN }}/{{ $json.result.file_path }}",
            "options":{"response":{"response":{"responseFormat":"file","outputPropertyName":"data"}}}},
         "id":uid(),"name":"Descargar Archivo Binario","type":"n8n-nodes-base.httpRequest",
         "typeVersion":4.2,"position":[0,160],"onError":"continueErrorOutput"},
        # 8
        {"parameters":{"jsCode":prepare_gemini_code,"mode":"runOnceForAllItems"},
         "id":uid(),"name":"Preparar Gemini","type":"n8n-nodes-base.code",
         "typeVersion":2,"position":[240,160],"onError":"continueErrorOutput"},
        # 9
        {"parameters":{
            "method":"POST","url":"={{ $json.gemini_url }}",
            "sendBody":True,"specifyBody":"json",
            "jsonBody":"={{ JSON.stringify($json.gemini_body) }}",
            "options":{"timeout":120000}},
         "id":uid(),"name":"Gemini Vision OCR","type":"n8n-nodes-base.httpRequest",
         "typeVersion":4.2,"position":[480,160],"onError":"continueErrorOutput"},
        # 10
        {"parameters":{"jsCode":parse_gemini_code,"mode":"runOnceForAllItems"},
         "id":uid(),"name":"Parsear Respuesta Gemini","type":"n8n-nodes-base.code",
         "typeVersion":2,"position":[720,160],"onError":"continueErrorOutput"},
        # 11
        {"parameters":{
            "conditions":{"options":{"caseSensitive":True,"leftValue":"","typeValidation":"loose"},
            "conditions":[
                {"id":uid(),"leftValue":"={{ $json.parse_error }}","rightValue":True,
                 "operator":{"type":"boolean","operation":"notEquals"}},
                {"id":uid(),"leftValue":"={{ $json.fecha_documento }}","rightValue":"",
                 "operator":{"type":"string","operation":"notEmpty","singleValue":True}},
                {"id":uid(),"leftValue":"={{ $json.proveedor }}","rightValue":"",
                 "operator":{"type":"string","operation":"notEmpty","singleValue":True}},
                {"id":uid(),"leftValue":"={{ $json.total }}","rightValue":"",
                 "operator":{"type":"number","operation":"exists","singleValue":True}},
            ],"combinator":"and"},"options":{}},
         "id":uid(),"name":"Documento Valido","type":"n8n-nodes-base.if",
         "typeVersion":2.2,"position":[960,160]},
        # 12
        {"parameters":{"resource":"message","operation":"sendMessage",
            "chatId":"={{ $json.chat_id }}",
            "text":"No fue posible leer correctamente el documento.","additionalFields":{}},
         "id":uid(),"name":"Telegram Lectura Fallida","type":"n8n-nodes-base.telegram",
         "typeVersion":1.2,"position":[1200,380],"credentials":TC},
        # 13
        {"parameters":{
            "operation":"executeQuery",
            "query":"SELECT id FROM documentos_contables WHERE numero_documento = ? AND proveedor = ? AND total = ? LIMIT 1;",
            "options":{"queryReplacement":"={{ $('Parsear Respuesta Gemini').item.json.numero_documento }},={{ $('Parsear Respuesta Gemini').item.json.proveedor }},={{ $('Parsear Respuesta Gemini').item.json.total }}"}},
         "id":uid(),"name":"Verificar Duplicado MySQL","type":"n8n-nodes-base.mySql",
         "typeVersion":2.4,"position":[1200,80],"credentials":MC,"onError":"continueErrorOutput"},
        # 14
        {"parameters":{
            "conditions":{"options":{"caseSensitive":True,"leftValue":"","typeValidation":"strict"},
            "conditions":[{"id":uid(),"leftValue":"={{ $json.id }}","rightValue":"",
                "operator":{"type":"number","operation":"exists","singleValue":True}}],
            "combinator":"and"},"options":{}},
         "id":uid(),"name":"Es Duplicado","type":"n8n-nodes-base.if",
         "typeVersion":2.2,"position":[1440,80]},
        # 15
        {"parameters":{"resource":"message","operation":"sendMessage",
            "chatId":"={{ $('Parsear Respuesta Gemini').item.json.chat_id }}",
            "text":"Documento ya registrado.","additionalFields":{}},
         "id":uid(),"name":"Telegram Duplicado","type":"n8n-nodes-base.telegram",
         "typeVersion":1.2,"position":[1680,280],"credentials":TC},
        # 16
        {"parameters":{"jsCode":build_path_code,"mode":"runOnceForAllItems"},
         "id":uid(),"name":"Construir Ruta Archivo","type":"n8n-nodes-base.code",
         "typeVersion":2,"position":[1680,-40]},
        # 17
        {"parameters":{"jsCode":restaurar_code,"mode":"runOnceForAllItems"},
         "id":uid(),"name":"Restaurar Datos Documento","type":"n8n-nodes-base.code",
         "typeVersion":2,"position":[1920,-40]},
        # 18
        {"parameters":{"operation":"write","fileName":"={{ $json.ruta_archivo }}",
            "dataPropertyName":"data","options":{}},
         "id":uid(),"name":"Guardar Archivo Original","type":"n8n-nodes-base.readWriteFile",
         "typeVersion":1,"position":[2160,-40],"onError":"continueErrorOutput"},
        # 19
        {"parameters":{
            "mode":"manual","duplicateItem":False,
            "assignments":{"assignments":[
                {"id":uid(),"name":"fecha_documento",   "value":"={{ $('Construir Ruta Archivo').item.json.fecha_documento }}","type":"string"},
                {"id":uid(),"name":"tipo_documento",    "value":"={{ $('Construir Ruta Archivo').item.json.tipo_documento }}","type":"string"},
                {"id":uid(),"name":"numero_documento",  "value":"={{ $('Construir Ruta Archivo').item.json.numero_documento }}","type":"string"},
                {"id":uid(),"name":"proveedor",         "value":"={{ $('Construir Ruta Archivo').item.json.proveedor }}","type":"string"},
                {"id":uid(),"name":"nit",               "value":"={{ $('Construir Ruta Archivo').item.json.nit }}","type":"string"},
                {"id":uid(),"name":"subtotal",          "value":"={{ Number($('Construir Ruta Archivo').item.json.subtotal)||0 }}","type":"number"},
                {"id":uid(),"name":"iva",               "value":"={{ Number($('Construir Ruta Archivo').item.json.iva)||0 }}","type":"number"},
                {"id":uid(),"name":"retenciones",       "value":"={{ Number($('Construir Ruta Archivo').item.json.retenciones)||0 }}","type":"number"},
                {"id":uid(),"name":"total",             "value":"={{ Number($('Construir Ruta Archivo').item.json.total)||0 }}","type":"number"},
                {"id":uid(),"name":"metodo_pago",       "value":"={{ $('Construir Ruta Archivo').item.json.metodo_pago }}","type":"string"},
                {"id":uid(),"name":"banco",             "value":"={{ $('Construir Ruta Archivo').item.json.banco }}","type":"string"},
                {"id":uid(),"name":"numero_comprobante","value":"={{ $('Construir Ruta Archivo').item.json.numero_comprobante }}","type":"string"},
                {"id":uid(),"name":"concepto",          "value":"={{ $('Construir Ruta Archivo').item.json.concepto }}","type":"string"},
                {"id":uid(),"name":"observaciones",     "value":"={{ $('Construir Ruta Archivo').item.json.observaciones }}","type":"string"},
                {"id":uid(),"name":"nombre_archivo",    "value":"={{ $('Construir Ruta Archivo').item.json.nombre_archivo }}","type":"string"},
                {"id":uid(),"name":"ruta_archivo",      "value":"={{ $('Construir Ruta Archivo').item.json.ruta_archivo }}","type":"string"},
                {"id":uid(),"name":"usuario_telegram",  "value":"={{ $('Construir Ruta Archivo').item.json.usuario_telegram }}","type":"string"},
            ]},"options":{}},
         "id":uid(),"name":"Mapear Insert MySQL","type":"n8n-nodes-base.set",
         "typeVersion":3.4,"position":[2400,-40]},
        # 20
        {"parameters":{
            "operation":"insert","table":"documentos_contables",
            "columns":"fecha_documento,tipo_documento,numero_documento,proveedor,nit,subtotal,iva,retenciones,total,metodo_pago,banco,numero_comprobante,concepto,observaciones,nombre_archivo,ruta_archivo,usuario_telegram",
            "options":{}},
         "id":uid(),"name":"Insertar MySQL","type":"n8n-nodes-base.mySql",
         "typeVersion":2.4,"position":[2640,-40],"credentials":MC,"onError":"continueErrorOutput"},
        # 21
        {"parameters":{"resource":"message","operation":"sendMessage",
            "chatId":"={{ $('Parsear Respuesta Gemini').item.json.chat_id }}",
            "text":"=✅ Documento registrado\n\nProveedor: {{ $('Parsear Respuesta Gemini').item.json.proveedor }}\nFecha: {{ $('Parsear Respuesta Gemini').item.json.fecha_documento }}\nValor: {{ $('Parsear Respuesta Gemini').item.json.total }}",
            "additionalFields":{}},
         "id":uid(),"name":"Telegram Confirmacion","type":"n8n-nodes-base.telegram",
         "typeVersion":1.2,"position":[2880,-40],"credentials":TC},
        # 22
        {"parameters":{"resource":"message","operation":"sendMessage",
            "chatId":"={{ $('Normalizar Entrada').item.json.chat_id || $('Telegram Trigger').item.json.message.chat.id }}",
            "text":"Ocurrio un error procesando el documento. Intente nuevamente.","additionalFields":{}},
         "id":uid(),"name":"Telegram Error Proceso","type":"n8n-nodes-base.telegram",
         "typeVersion":1.2,"position":[960,560],"credentials":TC},
    ]

    connections = {
        "Telegram Trigger":         {"main":[[c("Config Variables")]]},
        "Config Variables":         {"main":[[c("Normalizar Entrada")]]},
        "Normalizar Entrada":       {"main":[[c("Tiene Archivo Valido")],[c("Telegram Error Proceso")]]},
        "Tiene Archivo Valido":     {"main":[[c("Obtener Info Archivo")],[c("Telegram Archivo Invalido")]]},
        "Obtener Info Archivo":     {"main":[[c("Descargar Archivo Binario")],[c("Telegram Error Proceso")]]},
        "Descargar Archivo Binario":{"main":[[c("Preparar Gemini")],[c("Telegram Error Proceso")]]},
        "Preparar Gemini":          {"main":[[c("Gemini Vision OCR")],[c("Telegram Error Proceso")]]},
        "Gemini Vision OCR":        {"main":[[c("Parsear Respuesta Gemini")],[c("Telegram Error Proceso")]]},
        "Parsear Respuesta Gemini": {"main":[[c("Documento Valido")],[c("Telegram Error Proceso")]]},
        "Documento Valido":         {"main":[[c("Verificar Duplicado MySQL")],[c("Telegram Lectura Fallida")]]},
        "Verificar Duplicado MySQL":{"main":[[c("Es Duplicado")],[c("Telegram Error Proceso")]]},
        "Es Duplicado":             {"main":[[c("Telegram Duplicado")],[c("Construir Ruta Archivo")]]},
        "Construir Ruta Archivo":   {"main":[[c("Restaurar Datos Documento")]]},
        "Restaurar Datos Documento":{"main":[[c("Guardar Archivo Original")]]},
        "Guardar Archivo Original": {"main":[[c("Mapear Insert MySQL")],[c("Telegram Error Proceso")]]},
        "Mapear Insert MySQL":      {"main":[[c("Insertar MySQL")]]},
        "Insertar MySQL":           {"main":[[c("Telegram Confirmacion")],[c("Telegram Error Proceso")]]},
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

if __name__ == "__main__":
    w = build()
    path = "/workspace/n8n-workflows/workflow_facturas_telegram.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(w, f, ensure_ascii=False, indent=2)
    # validate JSON
    json.load(open(path))
    # validate connections
    names = {n['name'] for n in w['nodes']}
    errors = []
    for src, outs in w['connections'].items():
        if src not in names:
            errors.append(f"BAD SRC: {src}")
        for branch in outs.get('main', []):
            for conn in branch:
                if conn['node'] not in names:
                    errors.append(f"BAD TARGET: {src} -> {conn['node']}")
    if errors:
        for e in errors: print("ERROR:", e)
    else:
        print(f"OK — {len(w['nodes'])} nodos, 0 errores")
