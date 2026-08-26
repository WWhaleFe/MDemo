import Foundation
import MemoCore
import TestKit

let runner = TestRunner("MemoCore")

runner.test("ULID는 26자이며 생성 시각순으로 정렬된다") { t in
    let earlier = MemoID.generate(date: Date(timeIntervalSince1970: 1_000_000))
    let later = MemoID.generate(date: Date(timeIntervalSince1970: 2_000_000))

    t.expect(earlier.isValid, "이른 ID가 유효하지 않음: \(earlier)")
    t.expect(later.isValid, "늦은 ID가 유효하지 않음: \(later)")
    t.expectEqual(earlier.rawValue.count, 26)
    t.expect(earlier.rawValue < later.rawValue, "ULID는 문자열 정렬이 곧 시간순 정렬이어야 한다")
}

runner.test("같은 시각에 만들어도 ID는 충돌하지 않는다") { t in
    let now = Date()
    let ids = Set((0..<500).map { _ in MemoID.generate(date: now).rawValue })
    t.expectEqual(ids.count, 500, "중복 ID 발생")
}

runner.test("알파값은 하한선 아래로 내려가지 않는다 (OPA-03)") { t in
    let floored = MemoMeta(id: .generate(), backgroundAlpha: 0.0, textAlpha: 0.0)
    t.expectEqual(floored.backgroundAlpha, 0.15, "배경 알파 하한")
    t.expectEqual(floored.textAlpha, 0.3, "텍스트 알파 하한")

    let capped = MemoMeta(id: .generate(), backgroundAlpha: 2.0, textAlpha: 2.0)
    t.expectEqual(capped.backgroundAlpha, 1.0, "배경 알파 상한")
    t.expectEqual(capped.textAlpha, 1.0, "텍스트 알파 상한")
}

runner.test("배경색 프리셋 8가지가 모두 유효한 16진수다 (WIN-11)") { t in
    t.expectEqual(MemoColor.presets.count, 8)
    for preset in MemoColor.presets {
        t.expectNotNil(MemoColor.components(fromHex: preset.hex), "\(preset.name) 색상 파싱 실패")
    }
    t.expectNil(MemoColor.components(fromHex: "#XYZ"), "잘못된 색상 문자열은 거부해야 한다")
}

runner.test("메타데이터는 JSON 왕복 후에도 값이 보존된다") { t in
    let original = MemoMeta(id: .generate(), group: "업무", colorHex: "#FFF3B0", backgroundAlpha: 0.85)
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(MemoMeta.self, from: data)
    t.expectEqual(restored.id, original.id)
    t.expectEqual(restored.group, "업무")
    t.expectEqual(restored.backgroundAlpha, 0.85)
    t.expectEqual(restored.schemaVersion, MemoMeta.currentSchemaVersion)
}

runner.finish()
