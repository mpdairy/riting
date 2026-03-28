// Cloudflare Pages Function — proxies to Groq with rate limiting and caps.
//
// Required bindings (configure in Cloudflare dashboard):
//   - GROQ_API_KEY: secret (Settings > Environment variables)
//   - RITING_KV: KV namespace (Settings > Bindings)
//
// Optional environment variables:
//   - RATE_LIMIT_PER_DAY: max requests per IP per day (default 100)
//   - MAX_TOKENS_CAP: max tokens per request (default 100)
//   - MAX_PROMPT_CHARS: max characters in prompt content (default 15000)

var GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';
var MODEL = 'llama-3.3-70b-versatile';

export async function onRequestPost(context) {
  var { request, env } = context;

  // --- Rate limiting ---
  var ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  var today = new Date().toISOString().slice(0, 10);
  var rateKey = 'rl:' + ip + ':' + today;
  var limit = parseInt(env.RATE_LIMIT_PER_DAY) || 100;

  var current = parseInt(await env.RITING_KV.get(rateKey)) || 0;
  if (current >= limit) {
    return new Response(
      JSON.stringify({ error: 'Rate limited. Try again tomorrow!' }),
      { status: 429, headers: { 'Content-Type': 'application/json' } }
    );
  }
  await env.RITING_KV.put(rateKey, String(current + 1), { expirationTtl: 86400 });

  // --- Parse and validate ---
  var body;
  try {
    body = await request.json();
  } catch (e) {
    return new Response(
      JSON.stringify({ error: 'Invalid request body' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } }
    );
  }

  if (!body.messages || !Array.isArray(body.messages)) {
    return new Response(
      JSON.stringify({ error: 'Missing messages' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } }
    );
  }

  // --- Enforce caps ---
  var maxTokensCap = parseInt(env.MAX_TOKENS_CAP) || 100;
  var maxPromptChars = parseInt(env.MAX_PROMPT_CHARS) || 15000;

  // Force model and stream
  body.model = MODEL;
  body.stream = true;

  // Cap max_tokens
  if (!body.max_tokens || body.max_tokens > maxTokensCap) {
    body.max_tokens = maxTokensCap;
  }

  // Cap number of messages (frontend only sends 2: system + user)
  if (body.messages.length > 5) {
    return new Response(
      JSON.stringify({ error: 'Too many messages' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } }
    );
  }

  // Reject if total prompt content is too long
  var totalChars = 0;
  for (var i = 0; i < body.messages.length; i++) {
    if (body.messages[i].content) {
      totalChars += body.messages[i].content.length;
    }
  }
  if (totalChars > maxPromptChars) {
    return new Response(
      JSON.stringify({ error: 'Story is too long for the free tier' }),
      { status: 413, headers: { 'Content-Type': 'application/json' } }
    );
  }

  // --- Proxy to Groq ---
  var groqRes = await fetch(GROQ_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + env.GROQ_API_KEY,
    },
    body: JSON.stringify(body),
  });

  // Stream the response back
  return new Response(groqRes.body, {
    status: groqRes.status,
    headers: {
      'Content-Type': groqRes.headers.get('Content-Type') || 'text/event-stream',
      'Cache-Control': 'no-cache',
    },
  });
}

// CORS preflight (in case it's needed)
export async function onRequestOptions() {
  return new Response(null, {
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    },
  });
}
