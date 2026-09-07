const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 10000);
const ROOT = __dirname;
const TRANSLATION_API_URL = process.env.TRANSLATION_API_URL || 'https://api.mymemory.translated.net/get';
const TRANSLATION_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const translationCache = new Map();
const TRANSLATION_LANGUAGE_CODES = new Set(['ms', 'en', 'zh', 'es', 'fr', 'de', 'ja', 'ko', 'ar', 'hi', 'pt', 'ru', 'it', 'tr', 'id', 'th', 'vi', 'tl', 'bn', 'ur', 'fa', 'pl', 'uk', 'nl', 'sv', 'no', 'da', 'fi', 'el', 'he']);
const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json'
};

function sendJson(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*' });
  response.end(JSON.stringify(body));
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let body = '';
    request.on('data', chunk => {
      body += chunk;
      if (body.length > 12000) request.destroy(new Error('Request too large'));
    });
    request.on('end', () => resolve(body));
    request.on('error', reject);
  });
}

function normalizeTranslationLanguage(language) {
  const code = String(language || '').trim().toLowerCase().split('-')[0];
  if (code === 'fil') return 'tl';
  return TRANSLATION_LANGUAGE_CODES.has(code) ? code : null;
}

async function translateWithMyMemory(text, targetLanguage, sourceLanguage = 'auto') {
  const target = normalizeTranslationLanguage(targetLanguage);
  const source = sourceLanguage === 'auto' ? 'autodetect' : normalizeTranslationLanguage(sourceLanguage);
  if (!target || (!source && sourceLanguage !== 'auto')) throw new Error('Unsupported translation language');
  const cacheKey = `${source || 'autodetect'}:${target}:${text}`;
  const cached = translationCache.get(cacheKey);
  if (cached && cached.expiresAt > Date.now()) return cached.value;

  const url = new URL(TRANSLATION_API_URL);
  url.searchParams.set('q', text);
  url.searchParams.set('langpair', `${source || 'autodetect'}|${target}`);
  const upstream = await fetch(url, { headers: { Accept: 'application/json' } });
  const result = await upstream.json();
  if (!upstream.ok || Number(result.responseStatus) >= 400) throw new Error('Translation provider error');
  const translated = String(result.responseData?.translatedText || '').trim();
  if (!translated) throw new Error('Translation provider returned empty text');
  translationCache.set(cacheKey, { value: translated, expiresAt: Date.now() + TRANSLATION_CACHE_TTL_MS });
  return translated;
}

async function translate(request, response) {
  try {
    const payload = JSON.parse(await readBody(request));
    const text = String(payload.text || '').trim();
    const target = normalizeTranslationLanguage(payload.targetLanguage);
    if (!text || !target || text.length > 500) return sendJson(response, 400, { error: 'Invalid translation request' });
    const translation = await translateWithMyMemory(text, target, 'auto');
    return sendJson(response, 200, { translation });
  } catch (error) {
    console.error('Translation proxy error:', error.message);
    return sendJson(response, 500, { error: 'Translation request failed' });
  }
}

async function translateUi(request, response) {
  try {
    const payload = JSON.parse(await readBody(request));
    const translations = payload.translations && typeof payload.translations === 'object' ? payload.translations : {};
    const target = normalizeTranslationLanguage(payload.targetLanguage);
    const entries = Object.entries(translations).filter(([, value]) => typeof value === 'string' && value.length <= 1200).slice(0, 80);
    if (!entries.length || !target) return sendJson(response, 400, { error: 'Invalid UI translation request' });
    const translatedEntries = [];
    for (let index = 0; index < entries.length; index += 4) {
      const batch = entries.slice(index, index + 4);
      const results = await Promise.all(batch.map(async ([key, text]) => [key, await translateWithMyMemory(text, target, 'en')]));
      translatedEntries.push(...results);
    }
    return sendJson(response, 200, { translations: Object.fromEntries(translatedEntries) });
  } catch (error) {
    console.error('UI translation proxy error:', error.message);
    return sendJson(response, 502, { error: 'UI translation request failed' });
  }
}

function serveStatic(request, response) {
  const requestPath = decodeURIComponent(new URL(request.url, `http://${request.headers.host}`).pathname);
  const relativePath = requestPath === '/' || /^\/[A-Za-z0-9]{6}$/.test(requestPath) ? 'index.html' : requestPath.replace(/^\/+/, '');
  const filePath = path.resolve(ROOT, relativePath);
  if (!filePath.startsWith(ROOT) || !fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    response.writeHead(404); return response.end('Not found');
  }
  response.writeHead(200, { 'Content-Type': MIME_TYPES[path.extname(filePath).toLowerCase()] || 'application/octet-stream' });
  fs.createReadStream(filePath).pipe(response);
}

function isClearlyNonMobileUserAgent(userAgent) {
  const value = String(userAgent || '');
  if (/iPad/i.test(value)) return true;
  if (/Android/i.test(value) && !/Mobile/i.test(value)) return true;
  return /Windows NT|Macintosh|X11; Linux x86_64|CrOS/i.test(value);
}

function sendMobileOnlyBlock(response) {
  response.writeHead(403, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end('<!doctype html><html lang="ms"><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Infinity Chat</title></head><body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#0a0a0f;color:#f5f1e8;font:16px system-ui;text-align:center;padding:24px;box-sizing:border-box"><main><h1>📱 Infinity Chat hanya tersedia untuk telefon bimbit.</h1><p>Sila buka aplikasi menggunakan telefon anda.</p></main></body></html>');
}

const server = http.createServer(async (request, response) => {
  if (request.method === 'OPTIONS') {
    response.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, GET, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' });
    return response.end();
  }
  const requestPath = new URL(request.url, `http://${request.headers.host}`).pathname;
  if (request.method === 'POST' && requestPath === '/api/translate') return translate(request, response);
  if (request.method === 'POST' && requestPath === '/api/translate-ui') return translateUi(request, response);
  if (request.method === 'GET') {
    const acceptsHtml = String(request.headers.accept || '').includes('text/html');
    const isNonMobile = isClearlyNonMobileUserAgent(request.headers['user-agent']);
    if ((acceptsHtml || requestPath === '/manifest.json' || requestPath === '/service-worker.js') && isNonMobile) return sendMobileOnlyBlock(response);
    return serveStatic(request, response);
  }
  response.writeHead(405); response.end('Method not allowed');
});

server.listen(PORT, () => console.log(`Infinity Chat server listening on ${PORT}`));
