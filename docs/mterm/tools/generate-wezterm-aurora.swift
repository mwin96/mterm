import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = Array(CommandLine.arguments.dropFirst())
let auroraOutputPath = arguments.first ?? "/tmp/wezterm-aurora.png"
let dotsOutputPath = arguments.dropFirst().first ?? "/tmp/wezterm-dots.png"
let auroraWidth = 480
let auroraHeight = 300
let auroraFrameCount = 240
let auroraShortFrameDelay = 0.033
let auroraLongFrameDelay = 0.034
let auroraScale = CGFloat(auroraWidth) / 512
let dotsWidth = 1920
let dotsHeight = 1200
let colorSpace = CGColorSpaceCreateDeviceRGB()

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red / 255, green / 255, blue / 255, alpha])!
}

func drawBlob(
    _ context: CGContext,
    center: CGPoint,
    radius: CGFloat,
    color: CGColor,
    alpha: CGFloat
) {
    let components = color.components!
    let start = CGColor(
        colorSpace: colorSpace,
        components: [components[0], components[1], components[2], alpha]
    )!
    let end = CGColor(
        colorSpace: colorSpace,
        components: [components[0], components[1], components[2], 0]
    )!
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [start, end] as CFArray,
        locations: [0, 1]
    )!

    context.drawRadialGradient(
        gradient,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: [.drawsAfterEndLocation]
    )
}

struct BezierCurve {
    let p0: CGPoint
    let p1: CGPoint
    let p2: CGPoint
    let p3: CGPoint
}

func flowCurves(width: CGFloat, height: CGFloat, phase _: CGFloat) -> [BezierCurve] {
    [
        BezierCurve(
            p0: CGPoint(x: width * 0.28, y: height * 0.38),
            p1: CGPoint(x: width * 0.40, y: height * 0.30),
            p2: CGPoint(x: width * 0.48, y: height * 0.56),
            p3: CGPoint(x: width * 0.62, y: height * 0.52)
        ),
        BezierCurve(
            p0: CGPoint(x: width * 0.36, y: height * 0.64),
            p1: CGPoint(x: width * 0.44, y: height * 0.70),
            p2: CGPoint(x: width * 0.55, y: height * 0.42),
            p3: CGPoint(x: width * 0.69, y: height * 0.46)
        ),
    ]
}

func drawFlowCurve(
    _ context: CGContext,
    curve: BezierCurve,
    color: CGColor,
    dashPhase: CGFloat
) {
    let path = CGMutablePath()
    path.move(to: curve.p0)
    path.addCurve(to: curve.p3, control1: curve.p1, control2: curve.p2)

    context.saveGState()
    context.setLineCap(.round)
    context.addPath(path)
    context.setLineDash(phase: dashPhase, lengths: [9, 17])
    context.setLineWidth(0.65)
    context.setStrokeColor(color.copy(alpha: 0.11)!)
    context.strokePath()
    context.restoreGState()
}

func drawParticle(
    _ context: CGContext,
    center: CGPoint,
    radius: CGFloat,
    color: CGColor,
    alpha: CGFloat
) {
    context.saveGState()
    context.setFillColor(color.copy(alpha: alpha)!)
    context.fillEllipse(
        in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    )
    context.restoreGState()
}

func makeDestination(path: String, frameCount: Int) -> CGImageDestination {
    let outputURL = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL,
        UTType.gif.identifier as CFString,
        frameCount,
        nil
    ) else {
        fatalError("Unable to create GIF destination at \(path)")
    }

    CGImageDestinationSetProperties(
        destination,
        [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0,
        ],
        ] as CFDictionary
    )
    return destination
}

func makeAPNGDestination(path: String, frameCount: Int) -> CGImageDestination {
    let outputURL = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL,
        UTType.png.identifier as CFString,
        frameCount,
        nil
    ) else {
        fatalError("Unable to create APNG destination at \(path)")
    }

    CGImageDestinationSetProperties(
        destination,
        [
        kCGImagePropertyPNGDictionary: [
            kCGImagePropertyAPNGLoopCount: 0,
        ],
        ] as CFDictionary
    )
    return destination
}

func makeFrame(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to create animation frame")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    draw(graphics.cgContext)
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let image = bitmap.cgImage else {
        fatalError("Unable to create CGImage")
    }
    return image
}

func addFrame(_ image: CGImage, to destination: CGImageDestination, delay: Double) {
    CGImageDestinationAddImage(
        destination,
        image,
        [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay,
            kCGImagePropertyGIFUnclampedDelayTime: delay,
        ],
        ] as CFDictionary
    )
}

func addAPNGFrame(_ image: CGImage, to destination: CGImageDestination, delay: Double) {
    CGImageDestinationAddImage(
        destination,
        image,
        [
        kCGImagePropertyPNGDictionary: [
            kCGImagePropertyAPNGDelayTime: delay,
            kCGImagePropertyAPNGUnclampedDelayTime: delay,
        ],
        ] as CFDictionary
    )
}

let auroraDestination = makeAPNGDestination(
    path: auroraOutputPath,
    frameCount: auroraFrameCount
)
for frame in 0..<auroraFrameCount {
    autoreleasepool {
        let progress = CGFloat(frame) / CGFloat(auroraFrameCount)
        let phase = progress * .pi * 2
        let image = makeFrame(width: auroraWidth, height: auroraHeight) { context in
        context.clear(CGRect(x: 0, y: 0, width: auroraWidth, height: auroraHeight))
        context.setBlendMode(.normal)

        drawBlob(
            context,
            center: CGPoint(
                x: CGFloat(auroraWidth) * (0.08 + 0.13 * sin(phase)),
                y: CGFloat(auroraHeight) * (0.72 + 0.08 * cos(phase))
            ),
            radius: 350 * auroraScale,
            color: color(156, 207, 216),
            alpha: 0.34
        )
        drawBlob(
            context,
            center: CGPoint(
                x: CGFloat(auroraWidth) * (0.92 + 0.11 * cos(phase)),
                y: CGFloat(auroraHeight) * (0.30 + 0.09 * sin(phase * 2))
            ),
            radius: 360 * auroraScale,
            color: color(196, 167, 231),
            alpha: 0.31
        )
        drawBlob(
            context,
            center: CGPoint(
                x: CGFloat(auroraWidth) * (0.56 + 0.08 * sin(phase * 2 + 1.4)),
                y: CGFloat(auroraHeight) * (0.02 + 0.07 * cos(phase + 0.6))
            ),
            radius: 280 * auroraScale,
            color: color(235, 111, 146),
            alpha: 0.20
        )
        drawBlob(
            context,
            center: CGPoint(
                x: CGFloat(auroraWidth) * (0.32 + 0.08 * cos(phase + 2.0)),
                y: CGFloat(auroraHeight) * (1.04 + 0.05 * sin(phase * 2 + 0.4))
            ),
            radius: 250 * auroraScale,
            color: color(246, 193, 119),
            alpha: 0.12
        )

        let curves = flowCurves(
            width: CGFloat(auroraWidth),
            height: CGFloat(auroraHeight),
            phase: phase
        )
        drawFlowCurve(
            context,
            curve: curves[0],
            color: color(156, 207, 216),
            dashPhase: progress * 26
        )
        drawFlowCurve(
            context,
            curve: curves[1],
            color: color(196, 167, 231),
            dashPhase: -progress * 26
        )

        let particleColors = [
            color(224, 222, 244),
            color(156, 207, 216),
            color(196, 167, 231),
        ]
        for index in 0..<22 {
            let baseX = CGFloat((index * 37 + 11) % 97) / 96
            let baseY = CGFloat((index * 53 + 17) % 89) / 88
            let harmonicX = CGFloat(1 + index % 2)
            let harmonicY = CGFloat(1 + (index + 1) % 2)
            let amplitudeX = CGFloat(2 + index % 5)
            let amplitudeY = CGFloat(2 + (index * 3) % 5)
            let point = CGPoint(
                x: CGFloat(auroraWidth) * (0.14 + baseX * 0.72)
                    + sin(phase * harmonicX + CGFloat(index) * 0.73) * amplitudeX,
                y: CGFloat(auroraHeight) * (0.14 + baseY * 0.72)
                    + cos(phase * harmonicY + CGFloat(index) * 0.91) * amplitudeY
            )
            let radius = CGFloat(index % 7 == 0 ? 1.05 : 0.55 + Double(index % 3) * 0.13)
            let alpha = CGFloat(index % 7 == 0 ? 0.30 : 0.14 + Double(index % 4) * 0.025)
            drawParticle(
                context,
                center: point,
                radius: radius,
                color: particleColors[index % particleColors.count],
                alpha: alpha
            )
        }
        }
        let delay = frame % 3 == 2 ? auroraLongFrameDelay : auroraShortFrameDelay
        addAPNGFrame(image, to: auroraDestination, delay: delay)
    }
}

guard CGImageDestinationFinalize(auroraDestination) else {
    fatalError("Unable to finalize aurora APNG")
}

let dotsDestination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: dotsOutputPath) as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
)!
let dotSpacing = 58
let dotsImage = makeFrame(width: dotsWidth, height: dotsHeight) { context in
    context.clear(CGRect(x: 0, y: 0, width: dotsWidth, height: dotsHeight))
    for x in stride(from: -dotSpacing, through: dotsWidth + dotSpacing, by: dotSpacing) {
        for y in stride(from: -dotSpacing, through: dotsHeight + dotSpacing, by: dotSpacing) {
            let wave = 0.5 + 0.5 * sin(CGFloat(x) * 0.018 + CGFloat(y) * 0.014)
            let radius = 1.9 + 0.5 * wave
            context.setFillColor(color(224, 222, 244, 0.20 + 0.12 * wave))
            context.fillEllipse(
                in: CGRect(
                    x: CGFloat(x) - radius,
                    y: CGFloat(y) - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        }
    }
}
CGImageDestinationAddImage(dotsDestination, dotsImage, nil)

guard CGImageDestinationFinalize(dotsDestination) else {
    fatalError("Unable to finalize dots PNG")
}

print(auroraOutputPath)
print(dotsOutputPath)
