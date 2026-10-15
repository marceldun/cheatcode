import assert from "node:assert/strict";
import test from "node:test";
import worker, { buildOpenAIRequest, extractMessages, parseOpenAIText, verifyMetaSignature } from "../src/index.ts";

async function sign(body: Uint8Array, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signed = new Uint8Array(await crypto.subtle.sign("HMAC", key, body as BufferSource));
  return `sha256=${[...signed].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
}

test("verifies an authentic Meta webhook and rejects a modified body", async () => {
  const body = new TextEncoder().encode('{"entry":[]}');
  const signature = await sign(body, "secret");
  assert.equal(await verifyMetaSignature(body.buffer, signature, "secret"), true);
  assert.equal(await verifyMetaSignature(new TextEncoder().encode('{"entry":[1]}').buffer, signature, "secret"), false);
});

test("handles Meta verification and dispatches only signed webhook messages", async () => {
  const dispatched: string[] = [];
  const waits: Promise<unknown>[] = [];
  const env: any = {
    META_VERIFY_TOKEN: "verify",
    META_APP_SECRET: "app-secret",
    CONVERSATIONS: {
      idFromName: (name: string) => name,
      get: () => ({ fetch: async (_url: string, init: RequestInit) => { dispatched.push(String(init.body)); return new Response("sent"); } })
    }
  };
  const ctx: any = { waitUntil: (promise: Promise<unknown>) => waits.push(promise) };

  const verified = await worker.fetch(new Request("https://example.test/webhook?hub.mode=subscribe&hub.verify_token=verify&hub.challenge=123"), env, ctx);
  assert.equal(verified.status, 200);
  assert.equal(await verified.text(), "123");

  const payload = new TextEncoder().encode(JSON.stringify({ entry: [{ changes: [{ value: { messages: [{ id: "m1", from: "861", type: "text", text: { body: "Need shirts" } }] } }] }] }));
  const rejected = await worker.fetch(new Request("https://example.test/webhook", { method: "POST", body: payload, headers: { "x-hub-signature-256": "sha256=bad" } }), env, ctx);
  assert.equal(rejected.status, 401);

  const accepted = await worker.fetch(new Request("https://example.test/webhook", { method: "POST", body: payload, headers: { "x-hub-signature-256": await sign(payload, "app-secret") } }), env, ctx);
  assert.equal(accepted.status, 200);
  await Promise.all(waits);
  assert.equal(dispatched.length, 1);
  assert.match(dispatched[0], /Need shirts/);
});

test("extracts text, image, and interactive messages while ignoring status events", () => {
  const payload = { entry: [{ changes: [{ value: { statuses: [{ id: "status" }], messages: [
    { id: "m1", from: "861", type: "text", text: { body: "Need 500 hoodies" } },
    { id: "m2", from: "862", type: "image", image: { id: "img", caption: "Can you make this?", mime_type: "image/jpeg" } },
    { id: "m3", from: "863", type: "interactive", interactive: { button_reply: { id: "sample", title: "Order sample" } } }
  ] } }] }] };
  const result = extractMessages(payload);
  assert.equal(result.length, 3);
  assert.deepEqual(result[0], { id: "m1", from: "861", type: "text", text: "Need 500 hoodies" });
  assert.equal(result[1].mediaId, "img");
  assert.equal(result[2].text, "Order sample");
});

test("builds a guarded apparel export prompt with bounded history", () => {
  const history = Array.from({ length: 20 }, (_, i) => ({ role: (i % 2 ? "assistant" : "user") as "user" | "assistant", content: `m${i}` }));
  const request: any = buildOpenAIRequest("gpt-5-mini", "We make knitwear", history, "price?", "data:image/jpeg;base64,AA==");
  assert.equal(request.model, "gpt-5-mini");
  assert.match(request.instructions, /Never invent prices/);
  assert.match(request.instructions, /We make knitwear/);
  assert.equal(request.input.length, 17);
  assert.equal(request.input.at(-1).content[1].type, "input_image");
});

test("parses Responses API text", () => {
  assert.equal(parseOpenAIText({ output: [{ content: [{ type: "output_text", text: "  Hello buyer  " }] }] }), "Hello buyer");
  assert.throws(() => parseOpenAIText({ output: [] }), /no text/);
});

