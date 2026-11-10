# 중계 서버 첫 설정

이 폴더에는 파이널 퓨전의 중계 서버 코드가 들어 있습니다. 중계 서버는 두 앱 사이의 암호화된 데이터를 전달합니다.

1. 보내는 맥의 앱 실행 파일을 `--relay-id` 옵션과 함께 실행합니다. 출력된 64자리 공개 연결 번호를 사용합니다.
2. 폴더를 쓰기 가능한 곳에 복사합니다. 사용자가 배포를 승인한 Cloudflare Workers 계정에서 Wrangler로 배포합니다. 무료 플랜에서 사용할 수 있는 SQLite Durable Object가 설정돼 있습니다.

   ```sh
   npx wrangler login
   npx wrangler deploy --var STUDIO_ROOM:공개연결번호
   ```

3. 배포가 알려준 `https://…workers.dev` 주소의 `/health` 응답이 200인지 확인합니다. 보내는 앱의 **연결 서버**에 HTTPS 주소를 붙여넣거나, 앱 실행 파일을 `--set-relay <주소>` 옵션과 함께 실행합니다.
4. 앱에서 **보내기 시작**을 누릅니다. 중계 연결이 시작된 뒤 **받는 앱 만들기**를 누릅니다.

비공개 키는 보내는 맥에 저장됩니다. 배포 변수에는 `--relay-id`에서 출력한 공개 연결 번호만 사용하세요. 배포하려면 Cloudflare 계정이 필요합니다. [Workers 무료 사용량](https://developers.cloudflare.com/workers/platform/pricing/)
