# WhatsApp 官方 Cloud API + ChatGPT 服装外贸 AI 业务员

版本：**改进点—全自动接入 v3**。这是独立新副本，不覆盖 v2。

## 已实现

- Meta Webhook 验证和 `X-Hub-Signature-256` 防伪校验。
- 自动接收文字、图片、文档、按钮和列表回复。
- 图片交给 OpenAI 视觉模型分析；文字使用 Responses API。
- 按客户号码保存最近 16 条对话，防止重复提问。
- 按客户语言回复，执行服装 B2B 需求收集、异议处理和成交推进流程。
- 禁止编造价格、MOQ、交期、认证、库存和物流承诺。
- 使用消息 ID 去重，Meta 重试 Webhook 时不会重复回复。
- 部署在 Cloudflare Workers，普通流量可使用免费额度。

## 账号授权是强制条件

正式运行必须由账号所有者提供五项密钥：

1. `META_VERIFY_TOKEN`：自行生成的随机验证字符串。
2. `META_ACCESS_TOKEN`：Meta 系统用户的长期访问令牌。
3. `META_APP_SECRET`：Meta 应用密钥。
4. `META_PHONE_NUMBER_ID`：Cloud API 电话号码 ID。
5. `OPENAI_API_KEY`：OpenAI API 密钥；ChatGPT 会员不包含该额度。

这些密钥不要提交到 GitHub，也不要直接发送到聊天消息中。部署时使用 `wrangler secret put` 保存。

Windows 用户可以直接双击 `一键部署_Windows.bat`。脚本会完成 Cloudflare 登录、部署、自动生成 Webhook 验证字符串，并安全提示输入其余四项账号值。

## 部署命令

```bash
npm install
npx wrangler login
npx wrangler secret put META_VERIFY_TOKEN
npx wrangler secret put META_ACCESS_TOKEN
npx wrangler secret put META_APP_SECRET
npx wrangler secret put META_PHONE_NUMBER_ID
npx wrangler secret put OPENAI_API_KEY
npm run deploy
```

部署后的 Meta Webhook 地址为：

```text
https://whatsapp-clothing-export-ai-v3.<你的Cloudflare子域>.workers.dev/webhook
```

Meta Webhook 订阅字段选择 `messages`。上线前用 `/health` 检查版本，应返回 `{"ok":true,"version":3}`。

