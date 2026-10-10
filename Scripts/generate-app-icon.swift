#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let canvasSize: CGFloat = 1024

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

private func gradient(_ colors: [CGColor], locations: [CGFloat]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: locations
    )!
}

private func drawIcon(in context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let tileRect = CGRect(x: 56, y: 56, width: 912, height: 912)
    let tilePath = CGPath(
        roundedRect: tileRect,
        cornerWidth: 220,
        cornerHeight: 220,
        transform: nil
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -28),
        blur: 30,
        color: color(8, 19, 61, 0.34)
    )
    context.addPath(tilePath)
    context.setFillColor(color(36, 52, 160))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.drawLinearGradient(
        gradient(
            [color(82, 105, 242), color(51, 72, 202), color(23, 39, 118)],
            locations: [0, 0.52, 1]
        ),
        start: CGPoint(x: 170, y: 914),
        end: CGPoint(x: 850, y: 94),
        options: []
    )
    context.drawRadialGradient(
        gradient(
            [color(148, 184, 255, 0.62), color(98, 128, 255, 0.13), color(36, 55, 154, 0)],
            locations: [0, 0.55, 1]
        ),
        startCenter: CGPoint(x: 294, y: 810),
        startRadius: 0,
        endCenter: CGPoint(x: 294, y: 810),
        endRadius: 690,
        options: []
    )

    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: 56, y: 268))
    wave.addCurve(
        to: CGPoint(x: 590, y: 190),
        control1: CGPoint(x: 252, y: 388),
        control2: CGPoint(x: 440, y: 302)
    )
    wave.addCurve(
        to: CGPoint(x: 968, y: 108),
        control1: CGPoint(x: 708, y: 102),
        control2: CGPoint(x: 824, y: 55)
    )
    wave.addLine(to: CGPoint(x: 968, y: 56))
    wave.addLine(to: CGPoint(x: 56, y: 56))
    wave.closeSubpath()
    context.addPath(wave)
    context.setFillColor(color(14, 30, 102, 0.25))
    context.fillPath()

    let highlight = CGMutablePath()
    highlight.move(to: CGPoint(x: 104, y: 900))
    highlight.addCurve(
        to: CGPoint(x: 788, y: 806),
        control1: CGPoint(x: 306, y: 992),
        control2: CGPoint(x: 594, y: 958)
    )
    context.addPath(highlight)
    context.setStrokeColor(color(255, 255, 255, 0.16))
    context.setLineWidth(18)
    context.setLineCap(.round)
    context.strokePath()
    context.restoreGState()

    context.addPath(tilePath)
    context.setStrokeColor(color(255, 255, 255, 0.18))
    context.setLineWidth(10)
    context.strokePath()

    let paper = CGMutablePath()
    paper.move(to: CGPoint(x: 326, y: 876))
    paper.addLine(to: CGPoint(x: 606, y: 876))
    paper.addLine(to: CGPoint(x: 760, y: 722))
    paper.addLine(to: CGPoint(x: 760, y: 254))
    paper.addQuadCurve(to: CGPoint(x: 714, y: 208), control: CGPoint(x: 760, y: 208))
    paper.addLine(to: CGPoint(x: 326, y: 208))
    paper.addQuadCurve(to: CGPoint(x: 280, y: 254), control: CGPoint(x: 280, y: 208))
    paper.addLine(to: CGPoint(x: 280, y: 830))
    paper.addQuadCurve(to: CGPoint(x: 326, y: 876), control: CGPoint(x: 280, y: 876))
    paper.closeSubpath()

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -24),
        blur: 26,
        color: color(11, 24, 84, 0.38)
    )
    context.addPath(paper)
    context.setFillColor(color(244, 248, 255))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(paper)
    context.clip()
    context.drawLinearGradient(
        gradient([color(255, 255, 255), color(233, 242, 255)], locations: [0, 1]),
        start: CGPoint(x: 520, y: 876),
        end: CGPoint(x: 520, y: 208),
        options: []
    )
    context.restoreGState()

    let fold = CGMutablePath()
    fold.move(to: CGPoint(x: 606, y: 876))
    fold.addLine(to: CGPoint(x: 760, y: 722))
    fold.addLine(to: CGPoint(x: 654, y: 722))
    fold.addQuadCurve(to: CGPoint(x: 606, y: 770), control: CGPoint(x: 606, y: 722))
    fold.closeSubpath()
    context.saveGState()
    context.addPath(fold)
    context.clip()
    context.drawLinearGradient(
        gradient([color(220, 233, 255), color(191, 212, 252)], locations: [0, 1]),
        start: CGPoint(x: 636, y: 872),
        end: CGPoint(x: 728, y: 722),
        options: []
    )
    context.restoreGState()
    context.addPath(fold)
    context.setStrokeColor(color(175, 200, 244))
    context.setLineWidth(8)
    context.setLineJoin(.round)
    context.strokePath()

    for (rect, fillColor) in [
        (CGRect(x: 360, y: 588, width: 272, height: 28), color(80, 108, 189, 0.62)),
        (CGRect(x: 360, y: 522, width: 214, height: 28), color(80, 108, 189, 0.40))
    ] {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.setFillColor(fillColor)
        context.fillPath()
    }

    let badgeRect = CGRect(x: 562, y: 164, width: 284, height: 284)
    let badgePath = CGPath(ellipseIn: badgeRect, transform: nil)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -18),
        blur: 18,
        color: color(7, 24, 73, 0.38)
    )
    context.addPath(badgePath)
    context.setFillColor(color(8, 168, 232))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(badgePath)
    context.clip()
    context.drawLinearGradient(
        gradient([color(67, 221, 247), color(8, 168, 232)], locations: [0, 1]),
        start: CGPoint(x: 620, y: 406),
        end: CGPoint(x: 798, y: 214),
        options: []
    )
    context.restoreGState()

    context.addPath(CGPath(ellipseIn: badgeRect.insetBy(dx: 10, dy: 10), transform: nil))
    context.setStrokeColor(color(255, 255, 255, 0.28))
    context.setLineWidth(8)
    context.strokePath()

    context.setStrokeColor(color(255, 255, 255))
    context.setLineWidth(38)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 704, y: 232))
    context.addLine(to: CGPoint(x: 704, y: 380))
    context.move(to: CGPoint(x: 630, y: 306))
    context.addLine(to: CGPoint(x: 778, y: 306))
    context.strokePath()
}

private func renderIcon(pixelSize: Int, destination: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    let scale = CGFloat(pixelSize) / canvasSize
    context.scaleBy(x: scale, y: scale)
    drawIcon(in: context)

    guard
        let image = context.makeImage(),
        let destinationWriter = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    CGImageDestinationAddImage(destinationWriter, image, nil)
    guard CGImageDestinationFinalize(destinationWriter) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first
        ?? "QuickFileApp/Assets.xcassets/AppIcon.appiconset",
    isDirectory: true
)

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, pixelSize) in outputs {
    try renderIcon(
        pixelSize: pixelSize,
        destination: outputDirectory.appendingPathComponent(filename)
    )
}

print("Generated \(outputs.count) app icon images in \(outputDirectory.path)")
