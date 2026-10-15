const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const webPush = require('web-push');

const PORT = Number(process.env.PORT || 10000);
const ROOT = __dirname;
const TRANSLATION_API_URL = process.env.TRANSLATION_API_URL || 'https://api.mymemory.translated.net/get';
const TRANSLATION_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const CHAT_STICKER_MAX_BYTES = 2 * 1024 * 1024;
const CHAT_STICKER_TTL_MS = 24 * 60 * 60 * 1000;
const CHAT_STICKER_BUCKET = 'chat-stickers';
const CHAT_STICKER_ALLOWED_ORIGINS = new Set(
  (process.env.CHAT_STICKER_ALLOWED_ORIGINS || 'https://infinity-global-chat.onrender.com,http://localhost:3000,http://127.0.0.1:3000,http://localhost:5500,http://127.0.0.1:5500,http://localhost:10000,http://127.0.0.1:10000')
    .split(',')
    .map(origin => origin.trim())
    .filter(Boolean)
);
const CHAT_STICKER_MIME_EXTENSIONS = new Map([
  ['image/png', { extension: 'png', signature: buffer => buffer.length >= 8 && buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) }],
  ['image/jpeg', { extension: 'jpg', signature: buffer => buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff }],
  ['image/webp', { extension: 'webp', signature: buffer => buffer.length >= 12 && buffer.toString('ascii', 0, 4) === 'RIFF' && buffer.toString('ascii', 8, 12) === 'WEBP' }],
  ['image/gif', { extension: 'gif', signature: buffer => buffer.length >= 6 && ['GIF87a', 'GIF89a'].includes(buffer.toString('ascii', 0, 6)) }]
]);
const translationCache = new Map();
const chatStickerUploads = new Map();
let chatStickerCleanupRunning = false;
let chatStickerBucketMissingLogged = false;
const SUPABASE_URL = String(process.env.SUPABASE_URL || 'https://rptclztrmprcxjbolkrt.supabase.co').replace(/\/$/, '');
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || '';
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
const VAPID_PUBLIC_KEY = process.env.VAPID_PUBLIC_KEY || '';
const VAPID_PRIVATE_KEY = process.env.VAPID_PRIVATE_KEY || '';
const VAPID_SUBJECT = process.env.VAPID_SUBJECT || '';
const PUSH_WEBHOOK_SECRET = process.env.PUSH_WEBHOOK_SECRET || '';
const PUSH_ALLOWED_ORIGINS = new Set(
  (process.env.PUSH_ALLOWED_ORIGINS || 'https://infinity-global-chat.onrender.com')
    .split(',')
    .map(origin => origin.trim())
    .filter(Boolean)
);
const PUSH_CONFIGURED = Boolean(VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY && VAPID_SUBJECT);
if (PUSH_CONFIGURED) webPush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
const RAZORPAY_KEY_ID = process.env.RAZORPAY_KEY_ID || '';
const RAZORPAY_KEY_SECRET = process.env.RAZORPAY_KEY_SECRET || '';
const RAZORPAY_WEBHOOK_SECRET = process.env.RAZORPAY_WEBHOOK_SECRET || '';
const RAZORPAY_CURRENCY = String(process.env.RAZORPAY_CURRENCY || 'MYR').toUpperCase();
const RAZORPAY_PRO_PLAN_ID = process.env.RAZORPAY_PRO_PLAN_ID || process.env.RAZORPAY_PLAN_ID || '';
const RAZORPAY_PRO_AMOUNT = Number(process.env.RAZORPAY_PRO_AMOUNT || 3500);
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

function readBinaryBody(request, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let tooLarge = false;
    request.on('data', chunk => {
      size += chunk.length;
      if (size > maxBytes) {
        tooLarge = true;
        chunks.length = 0;
      } else if (!tooLarge) {
        chunks.push(chunk);
      }
    });
    request.on('end', () => {
      if (tooLarge) {
        const error = new Error('Sticker exceeds the upload size limit');
        error.statusCode = 413;
        reject(error);
      } else if (size === 0) {
        const error = new Error('Sticker image is empty');
        error.statusCode = 400;
        reject(error);
      } else {
        resolve(Buffer.concat(chunks, size));
      }
    });
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

function hasAllowedChatStickerOrigin(request) {
  return CHAT_STICKER_ALLOWED_ORIGINS.has(String(request.headers.origin || ''));
}

function getChatStickerUploadKey(request) {
  const forwardedFor = String(request.headers['x-forwarded-for'] || '');
  const ip = forwardedFor.split(',').map(value => value.trim()).filter(Boolean).pop()
    || request.socket.remoteAddress
    || 'unknown';
  const now = Date.now();
  const previous = chatStickerUploads.get(ip) || [];
  const recent = previous.filter(timestamp => now - timestamp < 10 * 60 * 1000);
  if (recent.length >= 12) return null;
  recent.push(now);
  chatStickerUploads.set(ip, recent);
  if (chatStickerUploads.size > 10000) {
    for (const [key, timestamps] of chatStickerUploads) {
      if (!timestamps.some(timestamp => now - timestamp < 10 * 60 * 1000)) chatStickerUploads.delete(key);
    }
  }
  return ip;
}

async function uploadChatSticker(request, response) {
  if (!hasAllowedChatStickerOrigin(request)) return sendJson(response, 403, { error: 'Sticker uploads are only accepted from the chat app' });
  if (!SUPABASE_SERVICE_ROLE_KEY) return sendJson(response, 503, { error: 'Sticker storage is not configured' });

  const mimeType = String(request.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
  const imageType = CHAT_STICKER_MIME_EXTENSIONS.get(mimeType);
  if (!imageType) return sendJson(response, 415, { error: 'Unsupported sticker image type' });
  const contentLength = Number(request.headers['content-length'] || 0);
  if (contentLength > CHAT_STICKER_MAX_BYTES) return sendJson(response, 413, { error: 'Sticker exceeds the upload size limit' });
  if (!getChatStickerUploadKey(request)) return sendJson(response, 429, { error: 'Sticker upload limit reached. Please wait before trying again.' });

  try {
    const image = await readBinaryBody(request, CHAT_STICKER_MAX_BYTES);
    if (!imageType.signature(image)) return sendJson(response, 415, { error: 'Sticker file does not match its image type' });

    const filename = `${Date.now()}-${crypto.randomUUID()}.${imageType.extension}`;
    const storageResponse = await fetch(`${SUPABASE_URL}/storage/v1/object/${CHAT_STICKER_BUCKET}/${filename}`, {
      method: 'POST',
      headers: getServiceRoleHeaders({
        'Content-Type': mimeType,
        'Cache-Control': 'max-age=60',
        'x-upsert': 'false'
      }),
      body: image
    });
    if (!storageResponse.ok) {
      const detail = await storageResponse.text();
      console.error('Supabase sticker upload failed:', storageResponse.status, detail.slice(0, 300));
      return sendJson(response, 502, { error: 'Sticker storage rejected the upload' });
    }
    const stickerUrl = `${SUPABASE_URL}/storage/v1/object/public/${CHAT_STICKER_BUCKET}/${filename}`;
    return sendJson(response, 201, { sticker_url: stickerUrl });
  } catch (error) {
    console.error('Chat sticker upload failed:', error.message);
    return sendJson(response, error.statusCode || 502, { error: error.statusCode ? error.message : 'Sticker upload failed' });
  }
}

async function cleanupOldChatStickers() {
  if (!SUPABASE_SERVICE_ROLE_KEY) throw new Error('Sticker cleanup requires SUPABASE_SERVICE_ROLE_KEY');
  if (chatStickerCleanupRunning) return true;
  chatStickerCleanupRunning = true;
  try {
    const expiredBefore = Date.now() - CHAT_STICKER_TTL_MS;
    const expiredNames = [];
    const pageSize = 100;
    let offset = 0;
    while (true) {
      const listResponse = await fetch(`${SUPABASE_URL}/storage/v1/object/list/${CHAT_STICKER_BUCKET}`, {
        method: 'POST',
        headers: getServiceRoleHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify({ prefix: '', limit: pageSize, offset, sortBy: { column: 'name', order: 'asc' } })
      });
      if (!listResponse.ok) {
        const detail = await listResponse.text();
        if (listResponse.status === 404 && !chatStickerBucketMissingLogged) {
          console.warn('Chat sticker cleanup is waiting for the chat-stickers Supabase bucket migration.');
          chatStickerBucketMissingLogged = true;
          return false;
        }
        throw new Error(`Storage list failed (${listResponse.status}): ${detail.slice(0, 200)}`);
      }
      chatStickerBucketMissingLogged = false;
      const objects = await listResponse.json();
      const page = Array.isArray(objects) ? objects : [];
      for (const object of page) {
        const match = /^([0-9]{13})-[a-f0-9-]{36}\.(?:png|jpg|webp|gif)$/i.exec(String(object.name || ''));
        if (match && Number(match[1]) < expiredBefore) expiredNames.push(object.name);
      }
      if (page.length < pageSize) break;
      offset += page.length;
    }

    for (let index = 0; index < expiredNames.length; index += 100) {
      const storageResponse = await fetch(`${SUPABASE_URL}/storage/v1/object/${CHAT_STICKER_BUCKET}`, {
        method: 'DELETE',
        headers: getServiceRoleHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify({ prefixes: expiredNames.slice(index, index + 100) })
      });
      if (!storageResponse.ok) {
        const detail = await storageResponse.text();
        throw new Error(`Storage delete failed (${storageResponse.status}): ${detail.slice(0, 200)}`);
      }
    }
    if (expiredNames.length) console.log(`Removed ${expiredNames.length} chat sticker(s) older than 24 hours.`);
    return true;
  } catch (error) {
    console.error('Chat sticker cleanup failed:', error.message);
    throw error;
  } finally {
    chatStickerCleanupRunning = false;
  }
}

function getServiceRoleHeaders(extra = {}) {
  return {
    apikey: SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    ...extra
  };
}

const CHAT_HOST_PERSONAS = [
  { name: 'Host Aina', avatar: '🤖' },
  { name: 'Host Daniel', avatar: '🤖' },
  { name: 'Host Maya', avatar: '🤖' },
  { name: 'Host Rafi', avatar: '🤖' },
  { name: 'Host Sofia', avatar: '🤖' }
];
const CHAT_HOST_TOPICS = {
  ms: [
    'Soalan santai: kalau boleh ubah satu perkara tentang kehidupan bandar, apa yang korang pilih?',
    'Topik debat ringan: kerja dari rumah lebih produktif atau pejabat lebih mudah fokus?',
    'Kalau ada satu kemahiran baharu yang boleh dipelajari percuma, korang nak belajar apa?',
    'Apa perkara kecil yang boleh buat komuniti setempat jadi lebih mesra?',
    'Cabaran harian: lebih penting jimat masa atau jimat duit? Kenapa?'
  ],
  en: [
    'Conversation starter: what is one small change that would make your city better?',
    'Friendly debate: does working from home help people focus, or is an office better?',
    'If you could learn one new skill for free, what would you choose?',
    'What is one practical way to make a local community more welcoming?',
    'Which matters more in daily life: saving time or saving money? Why?'
  ],
  zh: [
    '来聊个轻松的话题：如果能改变城市的一件事，你会选什么？',
    '友好辩论：在家工作更有效率，还是去办公室更容易专心？',
    '如果可以免费学一项新技能，你最想学什么？',
    '你觉得怎样才能让社区变得更友好？',
    '日常生活中，省时间和省钱哪个更重要？为什么？'
  ],
  ja: [
    '気軽な話題です。街を一つだけ変えられるなら、何を変えたいですか？',
    'ちょっとした議論：在宅勤務とオフィス勤務、どちらが集中できますか？',
    '無料で新しいスキルを一つ学べるなら、何を学びたいですか？',
    '地域をもっと住みやすくするために、何ができると思いますか？',
    '時間を節約することとお金を節約すること、どちらが大切ですか？'
  ],
  ko: [
    '가벼운 질문이에요. 도시에서 한 가지를 바꿀 수 있다면 무엇을 바꾸고 싶나요?',
    '편한 토론: 재택근무와 사무실 근무 중 어느 쪽이 더 집중이 잘 되나요?',
    '새로운 기술을 하나 무료로 배울 수 있다면 무엇을 배우고 싶나요?',
    '우리 동네를 더 살기 좋게 만들려면 무엇이 필요할까요?',
    '일상에서 시간 절약과 돈 절약 중 무엇이 더 중요하다고 생각하나요?'
  ],
  es: [
    'Para conversar: si pudieras cambiar una cosa de tu ciudad, ¿qué elegirías?',
    'Debate amistoso: ¿se trabaja mejor desde casa o en una oficina?',
    'Si pudieras aprender una habilidad nueva gratis, ¿cuál elegirías?',
    '¿Qué ayudaría a que la comunidad local fuera más acogedora?',
    'En el día a día, ¿qué importa más: ahorrar tiempo o ahorrar dinero?'
  ],
  fr: [
    'Pour discuter : si vous pouviez changer une chose dans votre ville, laquelle choisiriez-vous ?',
    'Petit débat : travaille-t-on mieux à la maison ou au bureau ?',
    'Si vous pouviez apprendre gratuitement une nouvelle compétence, laquelle choisiriez-vous ?',
    'Que faudrait-il pour rendre la communauté locale plus accueillante ?',
    'Au quotidien, qu’est-ce qui compte le plus : gagner du temps ou économiser ?'
  ],
  id: [
    'Topik santai: kalau bisa mengubah satu hal di kotamu, apa yang akan kamu pilih?',
    'Debat ringan: kerja dari rumah lebih produktif atau kantor lebih membantu fokus?',
    'Kalau bisa belajar satu keterampilan baru secara gratis, kamu ingin belajar apa?',
    'Apa yang bisa membuat lingkungan sekitar terasa lebih ramah?',
    'Dalam keseharian, mana yang lebih penting: hemat waktu atau hemat uang?'
  ]
};
const CHAT_HOST_LANGUAGE_BY_ROOM = {
  malaysia: 'ms', brunei: 'ms', indonesia: 'id',
  chinese: 'zh', china: 'zh', japan: 'ja', south_korea: 'ko',
  spain: 'es', mexico: 'es', argentina: 'es', colombia: 'es', chile: 'es',
  france: 'fr', belgium: 'fr', switzerland: 'fr'
};

function getChatHostMessage(room) {
  const persona = CHAT_HOST_PERSONAS[crypto.randomInt(CHAT_HOST_PERSONAS.length)];
  const topics = CHAT_HOST_TOPICS[CHAT_HOST_LANGUAGE_BY_ROOM[room] || 'en'];
  return {
    username: persona.name,
    avatar: persona.avatar,
    content: topics[crypto.randomInt(topics.length)]
  };
}

function getConfiguredChatRooms() {
  const indexHtml = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
  const channelList = indexHtml.match(/const CHANNELS = \[([\s\S]*?)\n    \];/);
  if (!channelList) throw new Error('Could not find configured chat rooms in index.html');
  const rooms = [...channelList[1].matchAll(/\{\s*id:\s*'([a-z0-9_]+)'/g)].map(match => match[1]);
  if (!rooms.length) throw new Error('No configured chat rooms were found');
  return [...new Set(rooms)];
}

async function runChatHostCycle() {
  if (!SUPABASE_SERVICE_ROLE_KEY) throw new Error('Chat host requires SUPABASE_SERVICE_ROLE_KEY');
  const registerResponse = await fetch(`${SUPABASE_URL}/rest/v1/rpc/register_chat_host_rooms`, {
    method: 'POST',
    headers: getServiceRoleHeaders({ 'Content-Type': 'application/json', Accept: 'application/json' }),
    body: JSON.stringify({ p_rooms: getConfiguredChatRooms() })
  });
  if (!registerResponse.ok) {
    throw new Error(`Could not register chat host rooms (${registerResponse.status}): ${(await registerResponse.text()).slice(0, 300)}`);
  }

  const candidateResponse = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_chat_host_candidates`, {
    method: 'POST',
    headers: getServiceRoleHeaders({ 'Content-Type': 'application/json', Accept: 'application/json' }),
    body: JSON.stringify({ p_limit: 200 })
  });
  if (!candidateResponse.ok) {
    throw new Error(`Could not load chat host rooms (${candidateResponse.status}): ${(await candidateResponse.text()).slice(0, 300)}`);
  }

  const candidates = await candidateResponse.json();
  let posted = 0;
  for (let index = 0; index < candidates.length; index += 20) {
    const batch = candidates.slice(index, index + 20);
    const results = await Promise.all(batch.map(async ({ room }) => {
      const message = getChatHostMessage(room);
      const postResponse = await fetch(`${SUPABASE_URL}/rest/v1/rpc/post_chat_host_message`, {
        method: 'POST',
        headers: getServiceRoleHeaders({ 'Content-Type': 'application/json', Accept: 'application/json' }),
        body: JSON.stringify({
          p_room: room,
          p_username: message.username,
          p_avatar: message.avatar,
          p_content: message.content
        })
      });
      if (!postResponse.ok) {
        throw new Error(`Could not post chat host message in ${room} (${postResponse.status}): ${(await postResponse.text()).slice(0, 300)}`);
      }
      return postResponse.json();
    }));
    posted += results.filter(Boolean).length;
    if (index + 20 < candidates.length) {
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
  console.info(`Chat host cycle completed: ${posted} messages posted across ${candidates.length} eligible rooms.`);
}

function hasAllowedPushOrigin(request) {
  const origin = String(request.headers.origin || '');
  return PUSH_ALLOWED_ORIGINS.has(origin);
}

async function getPushPublicKey(request, response) {
  if (!PUSH_CONFIGURED) return sendJson(response, 503, { error: 'Push notifications are not configured' });
  return sendJson(response, 200, { publicKey: VAPID_PUBLIC_KEY });
}

async function savePushSubscription(request, response) {
  if (!hasAllowedPushOrigin(request)) return sendJson(response, 403, { error: 'Push subscriptions are only accepted from the chat app' });
  if (!SUPABASE_SERVICE_ROLE_KEY) return sendJson(response, 503, { error: 'Push storage is not configured' });
  try {
    const payload = JSON.parse(await readBody(request));
    const subscription = payload.subscription;
    const deviceId = String(payload.deviceId || '').trim();
    const endpoint = String(subscription?.endpoint || '');
    if (!/^https:\/\//i.test(endpoint) || endpoint.length > 2048 || !subscription?.keys?.p256dh || !subscription?.keys?.auth || !deviceId || deviceId.length > 128) {
      return sendJson(response, 400, { error: 'Invalid push subscription' });
    }
    const user = await getSupabaseUser(request);
    const upstream = await fetch(`${SUPABASE_URL}/rest/v1/chat_push_subscriptions?on_conflict=endpoint`, {
      method: 'POST',
      headers: getServiceRoleHeaders({ 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates,return=minimal' }),
      body: JSON.stringify({
        endpoint,
        subscription,
        owner_device_id: deviceId,
        owner_user_id: user?.id || null,
        updated_at: new Date().toISOString()
      })
    });
    if (!upstream.ok) {
      console.error('Push subscription storage failed:', upstream.status, await upstream.text());
      return sendJson(response, 502, { error: 'Could not save push subscription' });
    }
    return sendJson(response, 200, { success: true });
  } catch (error) {
    console.error('Push subscription error:', error.message);
    return sendJson(response, 400, { error: 'Invalid push subscription request' });
  }
}

async function deletePushSubscription(request, response) {
  if (!hasAllowedPushOrigin(request)) return sendJson(response, 403, { error: 'Push subscriptions are only accepted from the chat app' });
  if (!SUPABASE_SERVICE_ROLE_KEY) return sendJson(response, 503, { error: 'Push storage is not configured' });
  try {
    const payload = JSON.parse(await readBody(request));
    const endpoint = String(payload.endpoint || '');
    const deviceId = String(payload.deviceId || '').trim();
    if (!/^https:\/\//i.test(endpoint) || endpoint.length > 2048 || !deviceId || deviceId.length > 128) {
      return sendJson(response, 400, { error: 'Invalid push subscription' });
    }
    const url = new URL(`${SUPABASE_URL}/rest/v1/chat_push_subscriptions`);
    url.searchParams.set('endpoint', `eq.${endpoint}`);
    url.searchParams.set('owner_device_id', `eq.${deviceId}`);
    const upstream = await fetch(url, { method: 'DELETE', headers: getServiceRoleHeaders() });
    if (!upstream.ok) {
      console.error('Push subscription removal failed:', upstream.status, await upstream.text());
      return sendJson(response, 502, { error: 'Could not remove push subscription' });
    }
    return sendJson(response, 200, { success: true });
  } catch (error) {
    console.error('Push subscription removal error:', error.message);
    return sendJson(response, 400, { error: 'Invalid push subscription request' });
  }
}

function secretsMatch(expected, actual) {
  const expectedBuffer = Buffer.from(expected);
  const actualBuffer = Buffer.from(actual);
  return expectedBuffer.length === actualBuffer.length && crypto.timingSafeEqual(expectedBuffer, actualBuffer);
}

async function dispatchChatPush(request, response) {
  if (!PUSH_CONFIGURED || !SUPABASE_SERVICE_ROLE_KEY) return sendJson(response, 503, { error: 'Push delivery is not configured' });
  const suppliedSecret = String(request.headers['x-push-webhook-secret'] || '');
  if (!PUSH_WEBHOOK_SECRET || !secretsMatch(PUSH_WEBHOOK_SECRET, suppliedSecret)) {
    return sendJson(response, 401, { error: 'Unauthorized push webhook' });
  }

  try {
    const payload = JSON.parse(await readBody(request));
    const message = payload.record || payload.new || payload;
    if (!message?.id || !message?.room || !message?.content) return sendJson(response, 400, { error: 'Invalid message event' });

    const upstream = await fetch(`${SUPABASE_URL}/rest/v1/chat_push_subscriptions?select=endpoint,subscription,owner_device_id,owner_user_id`, {
      headers: getServiceRoleHeaders({ Accept: 'application/json' })
    });
    if (!upstream.ok) {
      console.error('Could not load push recipients:', upstream.status, await upstream.text());
      return sendJson(response, 502, { error: 'Could not load push recipients' });
    }

    const subscriptions = await upstream.json();
    const recipients = subscriptions.filter(item =>
      item.owner_device_id !== message.owner_device_id
      && !(message.owner_user_id && item.owner_user_id === message.owner_user_id)
    );
    const sender = String(message.username || 'someone').slice(0, 40);
    const roomLabel = String(message.room)
      .replace(/_/g, ' ')
      .replace(/\b[a-z]/g, character => character.toUpperCase())
      .slice(0, 60);
    const notification = JSON.stringify({
      title: 'Infinity Global Chat',
      body: `New message from ${sender} in ${roomLabel}`,
      messageId: String(message.id),
      room: String(message.room)
    });
    let sent = 0;
    let expired = 0;
    for (let index = 0; index < recipients.length; index += 50) {
      const batch = recipients.slice(index, index + 50);
      const outcomes = await Promise.allSettled(batch.map(async recipient => {
        try {
          await webPush.sendNotification(recipient.subscription, notification, { TTL: 60 * 60 });
          sent++;
        } catch (error) {
          if (error.statusCode === 404 || error.statusCode === 410) {
            const url = new URL(`${SUPABASE_URL}/rest/v1/chat_push_subscriptions`);
            url.searchParams.set('endpoint', `eq.${recipient.endpoint}`);
            const removal = await fetch(url, { method: 'DELETE', headers: getServiceRoleHeaders() });
            if (!removal.ok) console.warn('Could not remove expired push subscription:', removal.status);
            expired++;
            return;
          }
          throw error;
        }
      }));
      outcomes.forEach(outcome => {
        if (outcome.status === 'rejected') console.warn('Push delivery failed:', outcome.reason?.statusCode || outcome.reason?.message);
      });
    }
    console.info(`Chat push dispatched: ${sent} sent, ${expired} expired, ${recipients.length} recipients.`);
    return sendJson(response, 200, { success: true, sent, expired });
  } catch (error) {
    console.error('Chat push dispatch failed:', error.message);
    return sendJson(response, 400, { error: 'Invalid push notification request' });
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

async function recordProAccessPayment(userId, subscriptionId, planId, paymentId, status = 'charged') {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/record_pro_access_payment`, {
    method: 'POST',
    headers: { apikey: SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_user_id: userId, p_subscription_id: subscriptionId, p_plan_id: planId, p_payment_id: paymentId, p_status: status })
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.message || 'Could not record Pro Access payment');
  return result;
}

async function updateProAccessStatus(subscriptionId, status) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/update_pro_access_status`, {
    method: 'POST',
    headers: { apikey: SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_subscription_id: subscriptionId, p_status: status })
  });
  if (!response.ok) throw new Error('Could not update Pro Access status');
  return response.json();
}

async function createRazorpayProSubscription(request, response) {
  if (!RAZORPAY_KEY_ID || !RAZORPAY_KEY_SECRET || !RAZORPAY_PRO_PLAN_ID || !SUPABASE_SERVICE_ROLE_KEY) {
    return sendJson(response, 503, { error: 'Pro subscription server configuration is incomplete' });
  }
  const user = await getSupabaseUser(request);
  if (!user?.id) return sendJson(response, 401, { error: 'Authentication required' });
  try {
    const auth = Buffer.from(`${RAZORPAY_KEY_ID}:${RAZORPAY_KEY_SECRET}`).toString('base64');
    const upstream = await fetch('https://api.razorpay.com/v1/subscriptions', {
      method: 'POST',
      headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ plan_id: RAZORPAY_PRO_PLAN_ID, total_count: 120, customer_notify: 1, notes: { user_id: user.id, product: 'infinity_chat_pro' } })
    });
    const result = await upstream.json();
    if (!upstream.ok) return sendJson(response, 502, { error: result.error?.description || 'Subscription creation failed' });
    return sendJson(response, 200, { id: result.id, status: result.status, key_id: RAZORPAY_KEY_ID, amount: RAZORPAY_PRO_AMOUNT, currency: RAZORPAY_CURRENCY });
  } catch (error) {
    console.error('Razorpay Pro subscription error:', error.message);
    return sendJson(response, 400, { error: 'Invalid Pro subscription request' });
  }
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
    const event = String(payload.event || '');
    const subscriptionEntity = payload.payload?.subscription?.entity;
    if (subscriptionEntity?.id) {
      const subscriptionId = String(subscriptionEntity.id);
      const status = String(subscriptionEntity.status || event.replace('subscription.', ''));
      if (event === 'subscription.charged') {
        const paymentEntity = payload.payload?.payment?.entity || {};
        const userId = String(subscriptionEntity.notes?.user_id || '');
        const planId = String(subscriptionEntity.plan_id || RAZORPAY_PRO_PLAN_ID);
        if (!userId || planId !== RAZORPAY_PRO_PLAN_ID || String(paymentEntity.currency || RAZORPAY_CURRENCY).toUpperCase() !== RAZORPAY_CURRENCY || Number(paymentEntity.amount) !== RAZORPAY_PRO_AMOUNT) {
          return sendJson(response, 400, { error: 'Invalid Pro subscription payment payload' });
        }
        await recordProAccessPayment(userId, subscriptionId, planId, String(paymentEntity.id || ''), 'charged');
      } else if (['subscription.cancelled', 'subscription.paused', 'subscription.halted', 'subscription.completed', 'subscription.updated', 'subscription.activated'].includes(event)) {
        await updateProAccessStatus(subscriptionId, status);
      }
      return sendJson(response, 200, { received: true, success: true });
    }
    if (event !== 'payment.captured') return sendJson(response, 200, { received: true });
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

const server = http.createServer(async (request, response) => {
  if (request.method === 'OPTIONS') {
    const requestPath = new URL(request.url, `http://${request.headers.host}`).pathname;
    if (requestPath === '/api/push/subscriptions' && !hasAllowedPushOrigin(request)) {
      response.writeHead(403, { 'Access-Control-Allow-Origin': '*' });
      return response.end();
    }
    if (requestPath === '/api/chat-stickers' && !hasAllowedChatStickerOrigin(request)) {
      response.writeHead(403, { 'Access-Control-Allow-Origin': '*' });
      return response.end();
    }
    response.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, DELETE, GET, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type, Authorization' });
    return response.end();
  }
  const requestPath = new URL(request.url, `http://${request.headers.host}`).pathname;
  if (request.method === 'POST' && requestPath === '/api/chat-stickers') return uploadChatSticker(request, response);
  if (request.method === 'GET' && requestPath === '/api/push/public-key') return getPushPublicKey(request, response);
  if (request.method === 'POST' && requestPath === '/api/push/subscriptions') return savePushSubscription(request, response);
  if (request.method === 'DELETE' && requestPath === '/api/push/subscriptions') return deletePushSubscription(request, response);
  if (request.method === 'POST' && requestPath === '/api/push/notify') return dispatchChatPush(request, response);
  if (request.method === 'POST' && requestPath === '/api/translate') return translate(request, response);
  if (request.method === 'POST' && requestPath === '/api/translate-ui') return translateUi(request, response);
  if (request.method === 'POST' && requestPath === '/api/razorpay/create-pro-subscription') return createRazorpayProSubscription(request, response);
  if (request.method === 'POST' && requestPath === '/api/razorpay/create-order') return createRazorpayOrder(request, response);
  if (request.method === 'POST' && requestPath === '/api/razorpay/verify-milestone') return verifyRazorpayMilestone(request, response);
  if (request.method === 'POST' && requestPath === '/api/razorpay/webhook') return handleRazorpayWebhook(request, response);
  if (request.method === 'GET') {
    return serveStatic(request, response);
  }
  response.writeHead(405); response.end('Method not allowed');
});

if (process.argv.includes('--cleanup-chat-stickers')) {
  cleanupOldChatStickers()
    .then(success => {
      if (!success) process.exitCode = 1;
    })
    .catch(error => {
      console.error('Chat sticker cleanup job failed:', error.message);
      process.exitCode = 1;
    });
} else if (process.argv.includes('--chat-host-cycle')) {
  runChatHostCycle()
    .catch(error => {
      console.error('Chat host cycle failed:', error.message);
      process.exitCode = 1;
    });
} else {
  server.listen(PORT, () => console.log(`Infinity Chat server listening on ${PORT}`));
}
