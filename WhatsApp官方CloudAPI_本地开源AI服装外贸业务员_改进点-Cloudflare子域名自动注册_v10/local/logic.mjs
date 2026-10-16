import { SYSTEM_PROMPT } from "./prompt.mjs";

export function buildOllamaRequest(config, history, job, imageBase64) {
  const user = { role: "user", content: job.text };
  if (imageBase64) user.images = [imageBase64];
  return {
    model: config.model,
    stream: false,
    think: false,
    messages: [
      { role: "system", content: `${SYSTEM_PROMPT}\n\nBusiness profile:\n${config.businessProfile}` },
      ...history.slice(-16),
      user
    ],
    options: { temperature: 0.25, num_ctx: 8192 }
  };
}

export function updatedHistory(history, userText, assistantText) {
  return [...history, { role: "user", content: userText }, { role: "assistant", content: assistantText }].slice(-16);
}

