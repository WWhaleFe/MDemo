# MDemo 노션 로그인 중계

노션 로그인은 토큰을 받을 때 비밀키(client_secret)가 필요하다. 비밀키를 앱에 넣지 않으려고 이 작은 서버가 코드 교환만 대신한다. 메모 내용은 이 서버를 지나지 않고, 앱이 노션 API와 직접 주고받는다.

- `GET /api/notion/callback`: 노션이 돌려보낸 코드를 사용자의 맥에서 기다리는 MDemo(127.0.0.1)로 넘긴다.
- `POST /api/notion/token`: `{ "code": ... }` 또는 `{ "refresh_token": ... }`를 노션 토큰으로 바꾼다.

## 배포 (Vercel Hobby, 무료)
1. 노션 개발자 포털에서 공개 통합을 만들고 Redirect URI를 `https://<배포 주소>/api/notion/callback`으로 등록한다.
2. Vercel 프로젝트 루트를 이 폴더로 두고 환경 변수 `NOTION_CLIENT_ID`, `NOTION_CLIENT_SECRET`, `NOTION_REDIRECT_URI`(위와 같은 주소)를 넣는다.
3. 앱의 `App/Resources/NotionOAuth.plist`에 `CLIENT_ID`, `RELAY_URL`(배포 주소)을 넣는다. 비밀키는 앱에 넣지 않는다.
