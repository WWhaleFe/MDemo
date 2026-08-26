# 개발 명령 모음. Xcode 없이 Command Line Tools만으로 동작한다.
.PHONY: build run release test check clean mem help

help:
	@echo "make build    - 디버그 빌드 + .app 번들 생성"
	@echo "make run      - 빌드 후 앱 실행 (메뉴바에 아이콘이 뜬다)"
	@echo "make release  - 유니버설(arm64+x86_64) 릴리스 번들"
	@echo "make test     - 전 패키지 테스트"
	@echo "make check    - 계층 규칙 · 네트워크 코드 검사"
	@echo "make mem      - 실행 중인 앱의 메모리 사용량 측정"
	@echo "make clean    - 빌드 산출물 삭제"

build:
	@Scripts/bundle.sh debug

run: build
	@pkill -x MemoApp 2>/dev/null || true
	@open build/MemoApp.app
	@echo "▸ 실행됨. 메뉴바의 메모 아이콘을 확인하세요."

release:
	@Scripts/bundle.sh release

# Xcode가 없어 swift test를 쓸 수 없으므로 각 패키지의 러너를 실행한다 (Packages/TestKit 참고)
test:
	@set -e; for pkg in MemoCore MarkdownEngine Services; do \
		(cd Packages/$$pkg && swift run -c debug $${pkg}Tests); \
	done
	@echo "✓ 전체 테스트 통과"

check:
	@Scripts/check-layering.sh

# 메모리 게이트 확인용 (NFR-02 / NFR-09)
mem:
	@ps -A -o rss,comm | grep -i "MemoApp" | grep -v grep | \
		awk '{printf "%s: %.1f MB\n", $$2, $$1/1024}' || echo "실행 중인 MemoApp 없음"

clean:
	@rm -rf build .build Packages/*/.build
	@echo "✓ 정리 완료"
