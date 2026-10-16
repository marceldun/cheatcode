export interface Env {
  META_VERIFY_TOKEN: string;
  META_ACCESS_TOKEN: string;
  META_APP_SECRET: string;
  META_PHONE_NUMBER_ID: string;
  META_GRAPH_VERSION?: string;
  AGENT_TOKEN: string;
  MESSAGE_QUEUE: DurableObjectNamespace;
}

export interface Job {
  id: string;
  from: string;
  type: string;
  text: string;
  mediaId?: string;
  mimeType?: string;
  enqueuedAt: number;
}

interface LeasedJob { job: Job; expiresAt: number }

export function extractJobs(payload: unknown, now = Date.now()): Job[] {
  const result: Job[] = [];
  const entries = (payload as any)?.entry;
  if (!Array.isArray(entries)) return result;
  for (const entry of entries) for (const change of entry?.changes ?? []) for (const message of change?.value?.messages ?? []) {
    const base = { id: String(message.id ?? ""), from: String(message.from ?? ""), type: String(message.type ?? ""), enqueuedAt: now };
    if (!base.id || !base.from) continue;
    if (message.type === "text") result.push({ ...base, text: String(message.text?.body ?? "").trim() });
    else if (message.type === "image") result.push({ ...base, text: String(message.image?.caption ?? "Please analyze this apparel reference image."), mediaId: message.image?.id, mimeType: message.image?.mime_type });
    else if (message.type === "document") result.push({ ...base, text: `The buyer sent a document${message.document?.filename ? ` named ${message.document.filename}` : ""}. Ask for the key specifications in text if the document cannot be read.` });
    else if (message.type === "button") result.push({ ...base, text: String(message.button?.text ?? message.button?.payload ?? "") });
    else if (message.type === "interactive") {
      const choice = message.interactive?.button_reply ?? message.interactive?.list_reply;
      result.push({ ...base, text: String(choice?.title ?? choice?.id ?? "") });
    } else result.push({ ...base, text: `The buyer sent a ${message.type} message. Ask them to resend the important content as text or an image.` });
  }
  return result;
}

function toHex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function verifyMetaSignature(raw: ArrayBuffer, signature: string | null, secret: string): Promise<boolean> {
  if (!secret || !signature?.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expected = `sha256=${toHex(await crypto.subtle.sign("HMAC", key, raw))}`;
  if (expected.length !== signature.length) return false;
  let mismatch = 0;
  for (let i = 0; i < expected.length; i++) mismatch |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  return mismatch === 0;
}

function bearerAuthorized(request: Request, token: string): boolean {
  const provided = request.headers.get("authorization") ?? "";
  const expected = `Bearer ${token}`;
  if (!token || provided.length !== expected.length) return false;
  let mismatch = 0;
  for (let i = 0; i < expected.length; i++) mismatch |= provided.charCodeAt(i) ^ expected.charCodeAt(i);
  return mismatch === 0;
}

async function sendWhatsApp(env: Env, to: string, text: string): Promise<void> {
  const version = env.META_GRAPH_VERSION || "v23.0";
  const response = await fetch(`https://graph.facebook.com/${version}/${encodeURIComponent(env.META_PHONE_NUMBER_ID)}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.META_ACCESS_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", recipient_type: "individual", to, type: "text", text: { preview_url: false, body: text.slice(0, 4000) } })
  });
  if (!response.ok) throw new Error(`Meta send failed: ${response.status} ${await response.text()}`);
}

export class MessageQueue {
  constructor(private state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const action = new URL(request.url).pathname;
    const pending = (await this.state.storage.get<Job[]>("pending")) ?? [];
    const leased = (await this.state.storage.get<Record<string, LeasedJob>>("leased")) ?? {};
    const now = Date.now();
    for (const [id, item] of Object.entries(leased)) if (item.expiresAt <= now) { pending.unshift(item.job); delete leased[id]; }

    if (action === "/enqueue") {
      const job = await request.json<Job>();
      if (await this.state.storage.get<boolean>(`seen:${job.id}`)) return new Response("duplicate");
      pending.push(job);
      await this.state.storage.put({ [`seen:${job.id}`]: true, pending, leased });
      return new Response("queued", { status: 201 });
    }
    if (action === "/pull") {
      const job = pending.shift();
      if (!job) { await this.state.storage.put({ pending, leased }); return new Response(null, { status: 204 }); }
      leased[job.id] = { job, expiresAt: now + 120_000 };
      await this.state.storage.put({ pending, leased });
      return Response.json(job);
    }
    if (action === "/ack") {
      const { id } = await request.json<{ id: string }>();
      delete leased[id];
      await this.state.storage.put({ pending, leased });
      return new Response("acknowledged");
    }
    return new Response("not found", { status: 404 });
  }
}

function queue(env: Env): DurableObjectStub {
  return env.MESSAGE_QUEUE.get(env.MESSAGE_QUEUE.idFromName("global"));
}

async function enqueueAll(env: Env, jobs: Job[]): Promise<void> {
  for (const job of jobs) {
    const response = await queue(env).fetch("https://queue.internal/enqueue", { method: "POST", body: JSON.stringify(job) });
    if (!response.ok) throw new Error(`Queue failed: ${response.status}`);
  }
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/webhook") {
      const valid = url.searchParams.get("hub.mode") === "subscribe" && url.searchParams.get("hub.verify_token") === env.META_VERIFY_TOKEN;
      return valid ? new Response(url.searchParams.get("hub.challenge") ?? "") : new Response("Forbidden", { status: 403 });
    }
    if (request.method === "POST" && url.pathname === "/webhook") {
      const raw = await request.arrayBuffer();
      if (!(await verifyMetaSignature(raw, request.headers.get("x-hub-signature-256"), env.META_APP_SECRET))) return new Response("Invalid signature", { status: 401 });
      const jobs = extractJobs(JSON.parse(new TextDecoder().decode(raw)));
      if (jobs.length) ctx.waitUntil(enqueueAll(env, jobs));
      return new Response("EVENT_RECEIVED");
    }
    if (url.pathname.startsWith("/agent/") && !bearerAuthorized(request, env.AGENT_TOKEN)) return new Response("Unauthorized", { status: 401 });
    if (request.method === "GET" && url.pathname === "/agent/pull") return queue(env).fetch("https://queue.internal/pull", { method: "POST" });
    if (request.method === "POST" && url.pathname === "/agent/reply") {
      const body = await request.json<{ id: string; to: string; text: string }>();
      if (!body.id || !body.to || !body.text?.trim()) return new Response("Invalid reply", { status: 400 });
      await sendWhatsApp(env, body.to, body.text.trim());
      await queue(env).fetch("https://queue.internal/ack", { method: "POST", body: JSON.stringify({ id: body.id }) });
      return new Response("sent");
    }
    if (request.method === "POST" && url.pathname === "/agent/drop") {
      const body = await request.json<{ id: string }>();
      if (!body.id) return new Response("Invalid job", { status: 400 });
      await queue(env).fetch("https://queue.internal/ack", { method: "POST", body: JSON.stringify({ id: body.id }) });
      return new Response("dropped");
    }
    if (request.method === "GET" && url.pathname === "/agent/media") {
      const id = url.searchParams.get("id");
      if (!id) return new Response("Missing media id", { status: 400 });
      const version = env.META_GRAPH_VERSION || "v23.0";
      const info = await fetch(`https://graph.facebook.com/${version}/${encodeURIComponent(id)}`, { headers: { Authorization: `Bearer ${env.META_ACCESS_TOKEN}` } });
      if (!info.ok) return new Response("Media metadata failed", { status: 502 });
      const metadata = await info.json<any>();
      const media = await fetch(metadata.url, { headers: { Authorization: `Bearer ${env.META_ACCESS_TOKEN}` } });
      return new Response(media.body, { status: media.status, headers: { "content-type": metadata.mime_type || media.headers.get("content-type") || "application/octet-stream" } });
    }
    if (url.pathname === "/health") return Response.json({ ok: true, version: 4, mode: "local-open-model" });
    return new Response("Not found", { status: 404 });
  }
};

