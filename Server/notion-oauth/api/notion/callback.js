// 노션 로그인 화면이 돌려보낸 코드를 사용자의 맥(127.0.0.1)에서 기다리는 MDemo로 넘긴다.
// state는 "<포트>.<무작위>" 형식이다. 포트만 꺼내 쓰고 값은 그대로 돌려보내 앱이 확인한다.
// 여기서는 토큰을 만들지 않고, 아무것도 기록하지 않는다.
const STATE = /^(\d{4,5})\.([A-Za-z0-9_-]{16,128})$/;

export default function handler(req, res) {
  const { code, state, error } = req.query;
  const match = typeof state === "string" ? STATE.exec(state) : null;
  const port = match ? Number(match[1]) : 0;
  if (!match || port < 1024 || port > 65535) {
    res.status(400).setHeader("Content-Type", "text/plain; charset=utf-8");
    res.send("잘못된 요청입니다. MDemo에서 다시 로그인해 주세요.");
    return;
  }
  const target = new URL(`http://127.0.0.1:${port}/notion`);
  target.searchParams.set("state", state);
  if (typeof error === "string") target.searchParams.set("error", error.slice(0, 100));
  else if (typeof code === "string") target.searchParams.set("code", code);
  res.setHeader("Cache-Control", "no-store");
  res.redirect(302, target.toString());
}
