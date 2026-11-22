// 앱 아이콘 원본(1024×1024 PNG)을 코드로 그린다.
//
// 사용법: swift Scripts/draw-icon.swift [출력.png]   (기본: App/Resources/AppIcon.png)
// 그 다음 Scripts/make-icon.sh 로 .icns를 만든다.
//
// 스타일: 거의 무채색 + 형광 라임 한 가지.
//   바탕 연회색, 앞 카드는 흰회색 메모(먹색 글줄), 뒤 카드는 사선 해칭 + 점선 테두리(대기 메모),
//   강조는 라임 점 하나. 캔버스를 꽉 채운 불투명 그림이라 macOS가 자기 틀로 잘라 보여 준다.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/App/Resources/AppIcon.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let ink = rgb(0x1B1C1F)
let lime = rgb(0xD4F53C)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// 위에서 아래로 재는 좌표로 그린다.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// 1. 바탕: 연회색, 위가 아주 조금 밝다.
let bg = CGGradient(colorsSpace: space, colors: [rgb(0xF0F1F3), rgb(0xE4E6EA)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// 2. 뒤 카드: 대기 메모. 사선 해칭 + 점선 테두리.
let back = CGRect(x: 330, y: 170, width: 500, height: 500)
ctx.saveGState()
ctx.addPath(rounded(back.insetBy(dx: 6, dy: 6), 86))
ctx.clip()
ctx.setStrokeColor(rgb(0xCDD0D6))
ctx.setLineWidth(10)
var x: CGFloat = back.minX - back.height
while x < back.maxX {
    ctx.move(to: CGPoint(x: x, y: back.maxY))
    ctx.addLine(to: CGPoint(x: x + back.height, y: back.minY))
    x += 40
}
ctx.strokePath()
ctx.restoreGState()
ctx.addPath(rounded(back.insetBy(dx: 4, dy: 4), 88))
ctx.setStrokeColor(rgb(0xA4A9B1))
ctx.setLineWidth(8)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [16, 20])
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

// 3. 앞 카드: 흰회색 메모, 옅고 넓은 그림자.
let front = CGRect(x: 194, y: 304, width: 540, height: 540)
let frontPath = rounded(front, 104)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -36), blur: 110, color: rgb(0x2A3140, 0.18))
ctx.addPath(frontPath)
ctx.setFillColor(rgb(0xFBFBFC))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x2A3140, 0.08))
ctx.addPath(frontPath)
ctx.setFillColor(rgb(0xFBFBFC))
ctx.fillPath()
ctx.restoreGState()

// 4. 먹색 글줄 세 개 (마지막은 짧게).
ctx.setFillColor(ink)
let lineX = front.minX + 92
for (i, width) in [CGFloat(330), 330, 196].enumerated() {
    let r = CGRect(x: lineX, y: front.minY + 150 + CGFloat(i) * 96, width: width, height: 42)
    ctx.addPath(rounded(r, 21))
}
ctx.fillPath()

// 5. 라임 점: 짧은 줄 끝, 지금 쓰는 자리.
ctx.setFillColor(lime)
ctx.fillEllipse(in: CGRect(x: lineX + 196 + 40, y: front.minY + 150 + 2 * 96 - 13, width: 68, height: 68))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("✓ 아이콘 원본: \(output)")
