import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// アプリアイコン（1024px・透過なし）を DeckCore のドット絵から描く（ios/scripts/make-app-icon.sh から呼ぶ）。

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// 背景: mac アプリの地の色から少し明るい色へ、上から下への縦のグラデーション。
let gradient = CGGradient(colorsSpace: space, colors: [rgb(0x16213a), rgb(0x0a0f1a)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// 絵の外接矩形を真ん中に置く（角は iOS が丸く切るので、余白を広めに取る）。
let runs = PixelCharacter.runs(for: .waiting, tick: 0)
let minX = runs.map(\.x).min()!, maxX = runs.map { $0.x + $0.width }.max()!
let minY = runs.map(\.y).min()!, maxY = runs.map { $0.y + 1 }.max()!
let cell = 40
let originX = (size - (maxX - minX) * cell) / 2 - minX * cell
let originY = (size - (maxY - minY) * cell) / 2 - minY * cell - cell / 2

// 足元の床（ステージの段）。
let floorTop = originY + maxY * cell
ctx.setFillColor(rgb(0x34d399).copy(alpha: 0.18)!)
ctx.fillEllipse(in: CGRect(x: size / 2 - 250, y: size - floorTop - 50, width: 500, height: 92))

ctx.setShouldAntialias(false)
for run in runs {
    ctx.setFillColor(rgb(run.color))
    // CoreGraphics は下が原点なので上下を返す。
    let y = size - (originY + (run.y + 1) * cell)
    ctx.fill(CGRect(x: originX + run.x * cell, y: y, width: run.width * cell, height: cell))
}

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: output)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("書き出せませんでした: \(output)") }
print("wrote \(output)")
