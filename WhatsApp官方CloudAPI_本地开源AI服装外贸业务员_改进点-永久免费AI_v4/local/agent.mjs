import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { buildOllamaRequest, updatedHistory } from "./logic.mjs";

const root = path.dirname(fileURLToPath(import.meta.url));
const config = JSON.parse(await fs.readFile(path.join(root, "config.json"), "utf8"));
const dataDir = path.join(root, "data");
const historyPath = path.join(dataDir, "history.json");
await fs.mkdir(dataDir, { recursive: true });
let histories = {};
try { histories = JSON.parse(await fs.readFile(historyPath, "utf8")); } catch {}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const auth = { Authorization: `Bearer ${config.agentToken}` };

async function saveHistories() {
  const temp = `${historyPath}.tmp`;
  await fs.writeFile(temp, JSON.stringify(histories), "utf8");
  await fs.rename(temp, historyPath);
}

async function fetchImage(mediaId) {
  const response = await fetch(`${config.workerUrl}/agent/media?id=${encodeURIComponent(mediaId)}`, { headers: auth });
  if (!response.ok) throw new Error(`Image download failed: ${response.status}`);
  return Buffer.from(await response.arrayBuffer()).toString("base64");
}

async function askModel(job) {
  const history = histories[job.from] ?? [];
  const image = job.mediaId ? await fetchImage(job.mediaId) : undefined;
  const request = buildOllamaRequest(config, history, job, image);
  const response = await fetch("http://127.0.0.1:11434/api/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request)
  });
  if (!response.ok) throw new Error(`Ollama failed: ${response.status} ${await response.text()}`);
  const body = await response.json();
  const text = String(body?.message?.content ?? "").trim();
  if (!text) throw new Error("Local model returned an empty reply");
  return { text, history };
}

async function handle(job) {
  if (Date.now() - Number(job.enqueuedAt) > 23 * 60 * 60 * 1000) {
    const dropped = await fetch(`${config.workerUrl}/agent/drop`, {
      method: "POST", headers: { ...auth, "Content-Type": "application/json" }, body: JSON.stringify({ id: job.id })
    });
    if (!dropped.ok) throw new Error(`Stale-job cleanup failed: ${dropped.status}`);
    console.log(`[${new Date().toLocaleString()}] dropped stale job ${job.id} to avoid a paid/out-of-window message`);
    return;
  }
  const { text, history } = await askModel(job);
  const response = await fetch(`${config.workerUrl}/agent/reply`, {
    method: "POST",
    headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify({ id: job.id, to: job.from, text })
  });
  if (!response.ok) throw new Error(`Reply delivery failed: ${response.status} ${await response.text()}`);
  histories[job.from] = updatedHistory(history, job.text, text);
  await saveHistories();
  console.log(`[${new Date().toLocaleString()}] replied to ${job.from}`);
}

console.log(`Local AI agent started with ${config.model}.`);
for (;;) {
  try {
    const response = await fetch(`${config.workerUrl}/agent/pull`, { headers: auth });
    if (response.status === 204) { await sleep(2000); continue; }
    if (!response.ok) throw new Error(`Queue poll failed: ${response.status} ${await response.text()}`);
    await handle(await response.json());
  } catch (error) {
    console.error(`[${new Date().toLocaleString()}]`, error?.message ?? error);
    await sleep(5000);
  }
}

process.on("unhandledRejection", (error) => console.error(error));

