const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 10000);
const ROOT = __dirname;
const TRANSLATION_API_URL = process.env.TRANSLATION_API_URL || 'https://api.mymemory.translated.net/get';
const TRANSLATION_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const translationCache = new Map();
const SUPABASE_URL = String(process.env.SUPABASE_URL || 'https://rptclztrmprcxjbolkrt.supabase.co').replace(/\/$/, '');
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || '';
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
const RAZORPAY_KEY_ID = process.env.RAZORPAY_KEY_ID || '';
const RAZORPAY_KEY_SECRET = process.env.RAZORPAY_KEY_SECRET || '';
const RAZORPAY_WEBHOOK_SECRET = process.env.RAZORPAY_WEBHOOK_SECRET || '';
const RAZORPAY_CURRENCY = String(process.env.RAZORPAY_CURRENCY || 'MYR').toUpperCase();
const TRANSLATION_LANGUAGE_CODES = new Set(['ms', 'en', 'zh', 'es', 'fr', 'de', 'ja', 'ko', 'ar', 'hi', 'pt', 'ru', 'it', 'tr', 'id', 'th', 'vi', 'tl', 'bn', 'ur', 'fa', 'pl', 'uk', 'nl', 'sv', 'no', 'da', 'fi', 'el', 'he']);
const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json'
};

function sendJson(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type, Authorization' });
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

function getBearerToken(request) {
  const value = String(request.headers.authorization || '');
  return value.startsWith('Bearer ') ? value.slice(7).trim() : '';
}

async function getSupabaseUser(request) {
  const token = getBearerToken(request);
  if (!token || !SUPABASE_ANON_KEY) return null;
  const upstream = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` } });
  if (!upstream.ok) return null;
  return upstream.json();
}

async function getGlobalWithdrawalStatus(request) {
  const token = getBearerToken(request);
  if (!token || !SUPABASE_ANON_KEY) return null;
  const upstream = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_global_withdrawal_status`, { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` } });
  if (!upstream.ok) return null;
  return upstream.json();
}

function validateMilestone(milestone) {
  const value = Number(milestone);
  return Number.isInteger(value) && value >= 1000 && value % 1000 === 0 ? value : null;
}

async function createRazorpayOrder(request, response) {
  if (!RAZORPAY_KEY_ID || !RAZORPAY_KEY_SECRET) return sendJson(response, 503, { error: 'Razorpay server configuration is incomplete' });
  const user = await getSupabaseUser(request);
  if (!user?.id) return sendJson(response, 401, { error: 'Authentication required' });
  try {
    const payload = JSON.parse(await readBody(request));
    const milestone = validateMilestone(payload.milestone);
    if (!milestone) return sendJson(response, 400, { error: 'Invalid milestone' });
    const status = await getGlobalWithdrawalStatus(request);
    if (!status || status.milestone !== milestone || !status.locked) return sendJson(response, 409, { error: 'This milestone is not currently locked for this account' });
    const auth = Buffer.from(`${RAZORPAY_KEY_ID}:${RAZORPAY_KEY_SECRET}`).toString('base64');
    const upstream = await fetch('https://api.razorpay.com/v1/orders', {
      method: 'POST',
      headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ amount: 3000, currency: RAZORPAY_CURRENCY, receipt: `milestone_${milestone}_${user.id.slice(0, 8)}`, notes: { user_id: user.id, milestone: String(milestone) } })
    });
    const result = await upstream.json();
    if (!upstream.ok) return sendJson(response, 502, { error: result.error?.description || 'Razorpay order creation failed' });
    return sendJson(response, 200, { id: result.id, amount: result.amount, currency: result.currency, key_id: RAZORPAY_KEY_ID });
  } catch (error) {
    console.error('Razorpay order error:', error.message);
    return sendJson(response, 400, { error: 'Invalid Razorpay order request' });
  }
}

function signaturesMatch(expected, actual) {
  const expectedBuffer = Buffer.from(expected || '');
  const actualBuffer = Buffer.from(actual || '');
  return expectedBuffer.length === actualBuffer.length && crypto.timingSafeEqual(expectedBuffer, actualBuffer);
}

async function verifyRazorpayMilestone(request, response) {
  if (!RAZORPAY_KEY_ID || !RAZORPAY_KEY_SECRET || !SUPABASE_SERVICE_ROLE_KEY) return sendJson(response, 503, { error: 'Payment verification server configuration is incomplete' });
  const user = await getSupabaseUser(request);
  if (!user?.id) return sendJson(response, 401, { error: 'Authentication required' });
  try {
    const payload = JSON.parse(await readBody(request));
    const milestone = validateMilestone(payload.milestone);
    const orderId = String(payload.razorpay_order_id || '');
    const paymentId = String(payload.razorpay_payment_id || '');
    const signature = String(payload.razorpay_signature || '');
    if (!milestone || !orderId || !paymentId || !signature) return sendJson(response, 400, { error: 'Incomplete payment verification data' });
    const expected = crypto.createHmac('sha256', RAZORPAY_KEY_SECRET).update(`${orderId}|${paymentId}`).digest('hex');
    if (!signaturesMatch(expected, signature)) return sendJson(response, 400, { error: 'Invalid payment signature' });
    const auth = Buffer.from(`${RAZORPAY_KEY_ID}:${RAZORPAY_KEY_SECRET}`).toString('base64');
    const paymentResponse = await fetch(`https://api.razorpay.com/v1/payments/${encodeURIComponent(paymentId)}`, { headers: { Authorization: `Basic ${auth}` } });
    const payment = await paymentResponse.json();
    if (!paymentResponse.ok || payment.order_id !== orderId || payment.amount !== 3000 || String(payment.currency).toUpperCase() !== RAZORPAY_CURRENCY || payment.status !== 'captured') return sendJson(response, 400, { error: 'Payment was not captured or does not match this order' });
    const orderResponse = await fetch(`https://api.razorpay.com/v1/orders/${encodeURIComponent(orderId)}`, { headers: { Authorization: `Basic ${auth}` } });
    const order = await orderResponse.json();
    const orderUserId = String(order.notes?.user_id || '');
    const orderMilestone = Number(order.notes?.milestone);
    if (!orderResponse.ok || order.id !== orderId || order.amount !== 3000 || String(order.currency).toUpperCase() !== RAZORPAY_CURRENCY || orderUserId !== user.id || orderMilestone !== milestone) return sendJson(response, 400, { error: 'Payment order does not match this account or milestone' });
    const rpcResponse = await fetch(`${SUPABASE_URL}/rest/v1/rpc/record_verified_global_milestone_payment`, { method: 'POST', headers: { apikey: SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_user_id: user.id, p_milestone: milestone, p_razorpay_order_id: orderId, p_razorpay_payment_id: paymentId, p_currency: RAZORPAY_CURRENCY }) });
    const result = await rpcResponse.json();
    if (!rpcResponse.ok) return sendJson(response, 502, { error: result.message || 'Could not record verified payment' });
    return sendJson(response, 200, { success: true, milestone });
  } catch (error) {
    console.error('Razorpay verification error:', error.message);
    return sendJson(response, 400, { error: 'Invalid payment verification request' });
  }
}

async function handleRazorpayWebhook(request, response) {
  if (!RAZORPAY_KEY_ID || !RAZORPAY_KEY_SECRET || !RAZORPAY_WEBHOOK_SECRET || !SUPABASE_SERVICE_ROLE_KEY) return sendJson(response, 503, { error: 'Razorpay webhook configuration is incomplete' });
  try {
    const body = await readBody(request);
    const signature = String(request.headers['x-razorpay-signature'] || '');
    const expected = crypto.createHmac('sha256', RAZORPAY_WEBHOOK_SECRET).update(body).digest('hex');
    if (!signaturesMatch(expected, signature)) return sendJson(response, 400, { error: 'Invalid webhook signature' });
    const payload = JSON.parse(body);
    if (payload.event !== 'payment.captured') return sendJson(response, 200, { received: true });
    const paymentId = String(payload.payload?.payment?.entity?.id || '');
    const orderId = String(payload.payload?.payment?.entity?.order_id || '');
    if (!paymentId || !orderId) return sendJson(response, 400, { error: 'Incomplete payment webhook data' });
    const auth = Buffer.from(`${RAZORPAY_KEY_ID}:${RAZORPAY_KEY_SECRET}`).toString('base64');
    const paymentResponse = await fetch(`https://api.razorpay.com/v1/payments/${encodeURIComponent(paymentId)}`, { headers: { Authorization: `Basic ${auth}` } });
    const payment = await paymentResponse.json();
    const orderResponse = await fetch(`https://api.razorpay.com/v1/orders/${encodeURIComponent(orderId)}`, { headers: { Authorization: `Basic ${auth}` } });
    const order = await orderResponse.json();
    const milestone = validateMilestone(order.notes?.milestone);
    const userId = String(order.notes?.user_id || '');
    if (!paymentResponse.ok || !orderResponse.ok || payment.order_id !== orderId || payment.amount !== 3000 || String(payment.currency).toUpperCase() !== RAZORPAY_CURRENCY || payment.status !== 'captured' || order.amount !== 3000 || String(order.currency).toUpperCase() !== RAZORPAY_CURRENCY || !milestone || !userId) return sendJson(response, 400, { error: 'Payment webhook does not match a valid milestone order' });
    const rpcResponse = await fetch(`${SUPABASE_URL}/rest/v1/rpc/record_verified_global_milestone_payment`, { method: 'POST', headers: { apikey: SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_user_id: userId, p_milestone: milestone, p_razorpay_order_id: orderId, p_razorpay_payment_id: paymentId, p_currency: RAZORPAY_CURRENCY }) });
    const result = await rpcResponse.json();
    if (!rpcResponse.ok) return sendJson(response, 502, { error: result.message || 'Could not record webhook payment' });
    return sendJson(response, 200, { received: true, success: true, milestone });
  } catch (error) {
    console.error('Razorpay webhook error:', error.message);
    return sendJson(response, 400, { error: 'Invalid Razorpay webhook request' });
  }
}

function serveStatic(request, response) {
  const requestPath = decodeURIComponent(new URL(request.url, `http://${request.headers.host}`).pathname);
  let relativePath = requestPath === '/' || /^\/[A-Za-z0-9]{6}$/.test(requestPath) ? 'index.html' : requestPath.replace(/^\/+/, '');

  if (!path.extname(relativePath)) {
    const candidate = path.resolve(ROOT, relativePath + '.html');
    if (fs.existsSync(candidate) && !fs.statSync(candidate).isDirectory()) {
      relativePath += '.html';
    }
  }

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
  if (request.method === 'POST' && requestPath === '/api/razorpay/create-order') return createRazorpayOrder(request, response);
  if (request.method === 'POST' && requestPath === '/api/razorpay/verify-milestone') return verifyRazorpayMilestone(request, response);
  if (request.method === 'POST' && requestPath === '/api/razorpay/webhook') return handleRazorpayWebhook(request, response);
  if (request.method === 'GET') {
    const acceptsHtml = String(request.headers.accept || '').includes('text/html');
    const isNonMobile = isClearlyNonMobileUserAgent(request.headers['user-agent']);
    const isDemoRoute = requestPath.startsWith('/demo/');
    if (!isDemoRoute && (acceptsHtml || requestPath === '/manifest.json' || requestPath === '/service-worker.js') && isNonMobile) return sendMobileOnlyBlock(response);
    return serveStatic(request, response);
  }
  response.writeHead(405); response.end('Method not allowed');
});

server.listen(PORT, () => console.log(`Infinity Chat server listening on ${PORT}`));
