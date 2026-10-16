import assert from "node:assert/strict";
import test from "node:test";
import worker, { extractJobs, MessageQueue, verifyMetaSignature } from "../cloud/worker.ts";
import { buildOllamaRequest, updatedHistory } from "../local/logic.mjs";

async function sign(body: Uint8Array, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signed = new Uint8Array(await crypto.subtle.sign("HMAC", key, body as BufferSource));
  return `sha256=${[...signed].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
}

test("validates Meta signatures and rejects tampering", async () => {
  const body = new TextEncoder().encode('{"entry":[]}');
  const signature = await sign(body, "secret");
  assert.equal(await verifyMetaSignature(body.buffer, signature, "secret"), true);
  assert.equal(await verifyMetaSignature(new TextEncoder().encode("changed").buffer, signature, "secret"), false);
});

test("extracts text and reference images but ignores status notifications", () => {
  const payload = { entry: [{ changes: [{ value: { statuses: [{ id: "s" }], messages: [
    { id: "m1", from: "441", type: "text", text: { body: "Need 800 hoodies" } },
    { id: "m2", from: "442", type: "image", image: { id: "img", mime_type: "image/jpeg", caption: "Quote this" } }
  ] } }] }] };
  const jobs = extractJobs(payload, 123);
  assert.equal(jobs.length, 2);
  assert.equal(jobs[0].text, "Need 800 hoodies");
  assert.equal(jobs[1].mediaId, "img");
  assert.equal(jobs[1].enqueuedAt, 123);
});

test("queue deduplicates, leases, acknowledges, and becomes empty", async () => {
  const map = new Map<string, unknown>();
  const state: any = { storage: {
    get: async (key: string) => map.get(key),
    put: async (key: string | Record<string, unknown>, value?: unknown) => {
      if (typeof key === "string") map.set(key, value);
      else for (const [name, item] of Object.entries(key)) map.set(name, item);
    }
  } };
  const queue = new MessageQueue(state);
  const job = { id: "m1", from: "1", type: "text", text: "hello", enqueuedAt: 1 };
  assert.equal((await queue.fetch(new Request("https://q/enqueue", { method: "POST", body: JSON.stringify(job) }))).status, 201);
  assert.equal(await (await queue.fetch(new Request("https://q/enqueue", { method: "POST", body: JSON.stringify(job) }))).text(), "duplicate");
  const pulled = await (await queue.fetch(new Request("https://q/pull", { method: "POST" }))).json() as any;
  assert.equal(pulled.id, "m1");
  assert.equal((await queue.fetch(new Request("https://q/ack", { method: "POST", body: JSON.stringify({ id: "m1" }) }))).status, 200);
  assert.equal((await queue.fetch(new Request("https://q/pull", { method: "POST" }))).status, 204);
});

test("guards local agent endpoints and accepts an authentic webhook", async () => {
  const queued: string[] = [];
  const waits: Promise<unknown>[] = [];
  const env: any = {
    META_VERIFY_TOKEN: "verify", META_APP_SECRET: "secret", AGENT_TOKEN: "agent",
    MESSAGE_QUEUE: { idFromName: () => "id", get: () => ({ fetch: async (_u: string, init: RequestInit) => { queued.push(String(init.body ?? "")); return new Response("queued", { status: 201 }); } }) }
  };
  const ctx: any = { waitUntil: (p: Promise<unknown>) => waits.push(p) };
  assert.equal((await worker.fetch(new Request("https://x/agent/pull"), env, ctx)).status, 401);
  const data = new TextEncoder().encode(JSON.stringify({ entry: [{ changes: [{ value: { messages: [{ id: "m", from: "1", type: "text", text: { body: "shirts" } }] } }] }] }));
  const response = await worker.fetch(new Request("https://x/webhook", { method: "POST", body: data, headers: { "x-hub-signature-256": await sign(data, "secret") } }), env, ctx);
  assert.equal(response.status, 200);
  await Promise.all(waits);
  assert.equal(queued.length, 1);
});

test("builds a bounded vision-capable local model request without invented terms", () => {
  const history = Array.from({ length: 20 }, (_, i) => ({ role: i % 2 ? "assistant" : "user", content: `m${i}` }));
  const request = buildOllamaRequest({ model: "qwen3-vl:8b", businessProfile: "Knitwear factory" }, history, { text: "price?" }, "base64-image");
  assert.equal(request.messages.length, 18);
  assert.deepEqual(request.messages.at(-1).images, ["base64-image"]);
  assert.match(request.messages[0].content, /Never invent/);
  assert.equal(updatedHistory(history, "u", "a").length, 16);
});
