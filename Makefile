# 개발 명령 모음. Xcode 없이 Command Line Tools만으로 동작한다.
.PHONY: build run release dist test check clean mem help

help:
	@echo "make build    - 디버그 빌드 + .app 번들 생성"
	@echo "make run      - 빌드 후 앱 실행 (메뉴바에 아이콘이 뜬다)"
	@echo "make release  - 유니버설(arm64+x86_64) 릴리스 번들"
	@echo "make dist     - 테스트용 배포 파일(.dmg, .zip)을 build/dist에 만든다"
	@echo "make test     - 전 패키지 테스트"
	@echo "make check    - 계층 규칙 · 네트워크 코드 검사"
	@echo "make mem      - 실행 중인 앱의 메모리 사용량 측정"
	@echo "make clean    - 빌드 산출물 삭제"

build:
	@Scripts/bundle.sh debug

run: build
	@pkill -x MDemo 2>/dev/null || true
	@open build/MDemo.app
	@echo "▸ 실행됨. 메뉴바의 메모 아이콘을 확인하세요."

release:
	@Scripts/bundle.sh release

# 다른 Mac에 옮겨 설치해 볼 테스트용 앱. 빌드 번호(커밋 수)를 넣고 dmg·zip으로 묶는다.
dist:
	@Scripts/package.sh

# Xcode 없이도 돌아가도록 swift test 대신 러너를 실행한다 (Packages/TestKit 참고)
test:
	@Scripts/test.sh

check:
	@Scripts/check-layering.sh

# 메모리 게이트 확인용 (NFR-02 / NFR-09)
mem:
	@ps -A -o rss,comm | grep -i "MDemo" | grep -v grep | \
		awk '{printf "%s: %.1f MB\n", $$2, $$1/1024}' || echo "실행 중인 MDemo 없음"

clean:
	@rm -rf build .build .build-shared Packages/*/.build
	@echo "✓ 정리 완료"
