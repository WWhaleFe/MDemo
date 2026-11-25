// 로그인 코드 또는 갱신 토큰을 노션 접근 토큰으로 바꾼다. 비밀키는 Vercel 환경 변수에만 있다.
// 메모 내용은 이 서버를 지나지 않는다. 요청과 응답을 기록하지 않는다.
const NOTION_TOKEN_URL = "https://api.notion.com/v1/oauth/token";

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") { res.status(405).json({ error: "method_not_allowed" }); return; }
  const id = process.env.NOTION_CLIENT_ID, secret = process.env.NOTION_CLIENT_SECRET, redirect = process.env.NOTION_REDIRECT_URI;
  if (!id || !secret || !redirect) { res.status(500).json({ error: "server_not_configured" }); return; }

  const body = typeof req.body === "string" ? safeParse(req.body) : (req.body ?? {});
  let payload;
  if (typeof body.code === "string" && body.code.length < 512) {
    payload = { grant_type: "authorization_code", code: body.code, redirect_uri: redirect };
  } else if (typeof body.refresh_token === "string" && body.refresh_token.length < 1024) {
    payload = { grant_type: "refresh_token", refresh_token: body.refresh_token };
  } else {
    res.status(400).json({ error: "invalid_request" }); return;
  }

  const notion = await fetch(NOTION_TOKEN_URL, {
    method: "POST",
    headers: {
      "Authorization": "Basic " + Buffer.from(`${id}:${secret}`).toString("base64"),
      "Content-Type": "application/json",
      "Notion-Version": "2022-06-28",
    },
    body: JSON.stringify(payload),
  });
  const text = await notion.text();
  res.status(notion.status).setHeader("Content-Type", "application/json").send(text);
}

function safeParse(text) { try { return JSON.parse(text); } catch { return {}; } }
