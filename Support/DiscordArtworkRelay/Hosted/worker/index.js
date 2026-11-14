const leaseSeconds = 300;
const challengeSeconds = 60;
const maxBytes = 64 * 1024;
const encoder = new TextEncoder();
const uuidPattern = "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}";
const coverPath = new RegExp("^/covers/(" + uuidPattern + ")\\.jpg$");
const challengePattern = new RegExp("^(" + uuidPattern + ")\\.(\\d{10})\\.([0-9a-f]{64})$");

function response(status, body = null, headers = {}) {
  return new Response(body, {
    status,
    headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...headers },
  });
}

function json(status, body) {
  return response(status, JSON.stringify(body), { "Content-Type": "application/json" });
}

async function sign(key, message) {
  const bytes = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2, "0")).join("");
}

async function authorize(request, env, now) {
  const ip = request.headers.get("CF-Connecting-IP");
  if (!ip || !env.RELAY_SIGNING_KEY || !env.RELAY_ORIGIN) return response(503);
  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(env.RELAY_SIGNING_KEY), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"],
  );
  const client = await sign(key, "client:" + ip);
  if (request.method === "GET") {
    const challenge = crypto.randomUUID() + "." + (now + challengeSeconds);
    return json(200, { challenge: challenge + "." + await sign(key, client + ":" + challenge) });
  }
  const challenge = request.headers.get("X-Artwork-Challenge") || "";
  const nonce = request.headers.get("X-Artwork-Proof") || "";
  const match = challengePattern.exec(challenge);
  if (!match || !/^\d{1,10}$/.test(nonce)) return response(401);
  const [, id, expiry, signature] = match;
  if (+expiry < now || +expiry > now + challengeSeconds) return response(401);
  const valid = await crypto.subtle.verify(
    "HMAC", key, Uint8Array.from(signature.match(/../g), byte => parseInt(byte, 16)), encoder.encode(client + ":" + id + "." + expiry),
  );
  if (!valid) return response(401);
  const proof = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(challenge + ":" + nonce)));
  if (proof[0] !== 0 || proof[1] !== 0) return response(401);
  return { client, id };
}

async function readImage(request) {
  if (request.headers.get("Content-Type") !== "image/jpeg") return response(415);
  if (!request.body) return response(400);
  if (Number(request.headers.get("Content-Length")) > maxBytes) return response(413);
  const reader = request.body.getReader();
  const data = new Uint8Array(maxBytes);
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (size + value.byteLength > maxBytes) {
      await reader.cancel();
      return response(413);
    }
    data.set(value, size);
    size += value.byteLength;
  }
  if (size < 4 || data[0] !== 255 || data[1] !== 216 || data[size - 2] !== 255 || data[size - 1] !== 217) {
    return response(415);
  }
  return data.slice(0, size);
}

async function upload(request, env, now) {
  const auth = await authorize(request, env, now);
  if (auth instanceof Response) return auth;
  const jpeg = await readImage(request);
  if (jpeg instanceof Response) return jpeg;
  const id = crypto.randomUUID();
  const [, inserted] = await env.DB.batch([
    env.DB.prepare("DELETE FROM covers WHERE expires_at <= ?").bind(now),
    env.DB.prepare(`INSERT OR IGNORE INTO covers (id, challenge, client, jpeg, expires_at)
      SELECT ?, ?, ?, ?, ?
      WHERE (SELECT count(*) FROM covers) < 256
        AND (SELECT count(*) FROM covers WHERE client = ?) < 12`)
      .bind(id, auth.id, auth.client, jpeg.buffer, now + leaseSeconds, auth.client),
  ]);
  if (inserted.meta.changes !== 1) return response(429, null, { "Retry-After": "30" });
  return json(201, { url: new URL("/covers/" + id + ".jpg", env.RELAY_ORIGIN).href, expiresIn: leaseSeconds });
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    const now = Math.floor(Date.now() / 1000);
    if (path === "/challenge" && request.method === "GET") return authorize(request, env, now);
    if (path === "/covers" && request.method === "POST") return upload(request, env, now);
    const match = coverPath.exec(path);
    if (match && (request.method === "GET" || request.method === "HEAD")) {
      const cover = await env.DB.prepare("SELECT jpeg FROM covers WHERE id = ? AND expires_at > ?")
        .bind(match[1], now).first();
      if (cover) {
        return response(200, request.method === "HEAD" ? null : new Uint8Array(cover.jpeg), {
          "Content-Type": "image/jpeg",
        });
      }
    }
    if (path === "/health" && request.method === "GET") {
      await env.DB.prepare("SELECT id FROM covers LIMIT 1").first();
      return json(200, { ok: true });
    }
    return response(404);
  },
};
