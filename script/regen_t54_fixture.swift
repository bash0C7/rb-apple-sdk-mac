// T54 — Vision OCR fixture image generator (Swift CLI version).
//
// Run via:
//   swift script/regen_t54_fixture.swift
//
// Outputs examples/fixtures/ocr_hello.png — 800×200 px, 白背景 / 黒文字
// (96pt Helvetica Bold) で "HELLO RUBY"。 Vision VNRecognizeTextRequest が
// default recognitionLevel で 99% 認識する高コントラスト条件。

import Cocoa

let outPath = ProcessInfo.processInfo.arguments.count > 1
    ? ProcessInfo.processInfo.arguments[1]
    : "examples/fixtures/ocr_hello.png"
let text = "HELLO RUBY"
let width: CGFloat = 800
let height: CGFloat = 200
let fontSize: CGFloat = 96

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()
NSColor.white.setFill()
NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))

let font = NSFont(name: "Helvetica-Bold", size: fontSize)!
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.black
]
let nsText = text as NSString
let textSize = nsText.size(withAttributes: attrs)
let x = (width - textSize.width) / 2
let y = (height - textSize.height) / 2
nsText.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiffData),
      let pngData = rep.representation(using: .png, properties: [:])
else { fatalError("PNG encode failed") }

let url = URL(fileURLWithPath: outPath)
try pngData.write(to: url)
print("wrote \(outPath) size=\(pngData.count)")
