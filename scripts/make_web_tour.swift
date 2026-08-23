import AppKit
import AVFoundation
import QuartzCore

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift make_web_tour.swift <input.mp4> <output.mp4>")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let asset = AVURLAsset(url: input)
guard let source = asset.tracks(withMediaType: .video).first else {
    fatalError("No video track")
}

let renderSize = CGSize(width: 1080, height: 1920)
let timescale: CMTimeScale = 600
let frame = 1.0 / 60.0
let introDuration = 3.2
let outroDuration = 3.6
let sourceDuration = CMTimeGetSeconds(asset.duration)

let composition = AVMutableComposition()
guard let track = composition.addMutableTrack(
    withMediaType: .video,
    preferredTrackID: kCMPersistentTrackID_Invalid
) else { fatalError("Cannot create video track") }

func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: timescale)
}

func insertFreeze(_ instant: Double, duration: Double, at cursor: CMTime) throws {
    try track.insertTimeRange(
        CMTimeRange(start: time(instant), duration: time(frame)),
        of: source,
        at: cursor
    )
    track.scaleTimeRange(
        CMTimeRange(start: cursor, duration: time(frame)),
        toDuration: time(duration)
    )
}

struct Segment {
    let sourceStart: Double
    let sourceEnd: Double
    let speed: Double
}

// The quiet moments stay natural. Saving and scanning are slowed down so the
// viewer can understand what changed without turning the whole tour sluggish.
let segments = [
    Segment(sourceStart: 0.0, sourceEnd: 4.0, speed: 0.90),
    Segment(sourceStart: 4.0, sourceEnd: 14.0, speed: 1.18),
    Segment(sourceStart: 14.0, sourceEnd: 18.5, speed: 0.82),
    Segment(sourceStart: 18.5, sourceEnd: 22.8, speed: 0.78),
    Segment(sourceStart: 22.8, sourceEnd: 26.2, speed: 1.00),
    Segment(sourceStart: 26.2, sourceEnd: 30.3, speed: 0.78),
    Segment(sourceStart: 30.3, sourceEnd: 34.4, speed: 0.92),
    Segment(sourceStart: 34.4, sourceEnd: min(38.15, sourceDuration), speed: 0.78),
]

try insertFreeze(0, duration: introDuration, at: .zero)
var cursor = time(introDuration)
var contentRanges: [(start: Double, end: Double)] = []

for segment in segments where segment.sourceEnd > segment.sourceStart {
    let originalDuration = segment.sourceEnd - segment.sourceStart
    let outputDuration = originalDuration / segment.speed
    let start = CMTimeGetSeconds(cursor)
    let insertedRange = CMTimeRange(start: cursor, duration: time(originalDuration))
    try track.insertTimeRange(
        CMTimeRange(start: time(segment.sourceStart), duration: time(originalDuration)),
        of: source,
        at: cursor
    )
    track.scaleTimeRange(insertedRange, toDuration: time(outputDuration))
    cursor = CMTimeAdd(cursor, time(outputDuration))
    contentRanges.append((start: start, end: CMTimeGetSeconds(cursor)))
}

let outroStart = CMTimeGetSeconds(cursor)
try insertFreeze(max(0, sourceDuration - frame), duration: outroDuration, at: cursor)
let totalDuration = CMTimeGetSeconds(composition.duration)

let instruction = AVMutableVideoCompositionInstruction()
instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
instruction.backgroundColor = NSColor(
    calibratedRed: 0.94,
    green: 0.985,
    blue: 0.96,
    alpha: 1
).cgColor
let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)

// The app stays completely visible. Text lives above it instead of covering UI.
let phoneHeight: CGFloat = 1450
let sourceSize = source.naturalSize
let scale = phoneHeight / sourceSize.height
let phoneWidth = sourceSize.width * scale
let phoneX = (renderSize.width - phoneWidth) / 2
let phoneY: CGFloat = 145
layerInstruction.setTransform(
    CGAffineTransform(scaleX: scale, y: scale)
        .translatedBy(x: phoneX / scale, y: phoneY / scale),
    at: .zero
)
instruction.layerInstructions = [layerInstruction]

let videoComposition = AVMutableVideoComposition()
videoComposition.renderSize = renderSize
videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
videoComposition.instructions = [instruction]

let green = NSColor(calibratedRed: 0.08, green: 0.66, blue: 0.36, alpha: 1)
let deepGreen = NSColor(calibratedRed: 0.025, green: 0.16, blue: 0.105, alpha: 1)
let ink = NSColor(calibratedRed: 0.025, green: 0.10, blue: 0.072, alpha: 1)
let muted = NSColor(calibratedRed: 0.29, green: 0.40, blue: 0.34, alpha: 1)
let cream = NSColor(calibratedRed: 0.94, green: 0.985, blue: 0.96, alpha: 1)

let parent = CALayer()
parent.frame = CGRect(origin: .zero, size: renderSize)
parent.backgroundColor = cream.cgColor

let gradient = CAGradientLayer()
gradient.frame = parent.bounds
gradient.colors = [
    NSColor(calibratedRed: 0.91, green: 0.985, blue: 0.945, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.975, green: 0.995, blue: 0.982, alpha: 1).cgColor,
    NSColor.white.cgColor,
]
gradient.locations = [0, 0.58, 1]
gradient.startPoint = CGPoint(x: 0.08, y: 0.92)
gradient.endPoint = CGPoint(x: 0.92, y: 0.08)
parent.addSublayer(gradient)

let glow = CALayer()
glow.frame = CGRect(x: -250, y: 1150, width: 1580, height: 980)
glow.cornerRadius = 490
glow.backgroundColor = green.withAlphaComponent(0.09).cgColor
parent.addSublayer(glow)

let phoneCard = CALayer()
phoneCard.frame = CGRect(x: phoneX - 20, y: phoneY - 20, width: phoneWidth + 40, height: phoneHeight + 40)
phoneCard.cornerRadius = 54
phoneCard.backgroundColor = NSColor.white.cgColor
phoneCard.borderWidth = 1
phoneCard.borderColor = green.withAlphaComponent(0.16).cgColor
phoneCard.shadowColor = deepGreen.cgColor
phoneCard.shadowOpacity = 0.20
phoneCard.shadowRadius = 34
phoneCard.shadowOffset = CGSize(width: 0, height: -10)
parent.addSublayer(phoneCard)

let videoLayer = CALayer()
videoLayer.frame = parent.bounds
parent.addSublayer(videoLayer)

// AVFoundation fills the area outside the transformed recording itself. A light
// background plus a soft top wash keeps every caption readable and removes the
// old black banner entirely.
let topWash = CAGradientLayer()
topWash.frame = CGRect(x: 0, y: 1610, width: renderSize.width, height: 310)
topWash.colors = [
    NSColor(calibratedRed: 0.92, green: 0.985, blue: 0.95, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.98, green: 0.997, blue: 0.986, alpha: 1).cgColor,
]
topWash.startPoint = CGPoint(x: 0, y: 0)
topWash.endPoint = CGPoint(x: 1, y: 1)
parent.addSublayer(topWash)

let phoneOutline = CALayer()
phoneOutline.frame = phoneCard.frame
phoneOutline.cornerRadius = phoneCard.cornerRadius
phoneOutline.borderWidth = 2
phoneOutline.borderColor = green.withAlphaComponent(0.16).cgColor
parent.addSublayer(phoneOutline)

func textLayer(
    _ text: String,
    frame: CGRect,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor = ink,
    alignment: NSTextAlignment = .center
) -> CALayer {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: max(1, Int(frame.width * 2)),
        pixelsHigh: max(1, Int(frame.height * 2)),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    bitmap.size = frame.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: frame.size).fill()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    let attributed = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ])
    let measured = attributed.boundingRect(
        with: frame.size,
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height
    attributed.draw(in: CGRect(
        x: 0,
        y: max(0, (frame.height - measured) / 2),
        width: frame.width,
        height: min(frame.height, measured + 10)
    ))
    NSGraphicsContext.restoreGraphicsState()
    let layer = CALayer()
    layer.frame = frame
    layer.contents = bitmap.cgImage
    layer.contentsGravity = .resize
    return layer
}

func opacityAnimation(
    values: [NSNumber],
    times: [NSNumber],
    duration: Double
) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    animation.values = values
    animation.keyTimes = times
    animation.duration = duration
    animation.beginTime = AVCoreAnimationBeginTimeAtZero
    animation.isRemovedOnCompletion = false
    animation.fillMode = .both
    return animation
}

func show(_ layer: CALayer, start: Double, end: Double, fade: Double = 0.34) {
    let safeStart = max(0, min(start, totalDuration))
    let safeEnd = max(safeStart, min(end, totalDuration))
    let fadeInEnd = min(safeEnd, safeStart + fade)
    let fadeOutStart = max(fadeInEnd, safeEnd - fade)
    layer.add(opacityAnimation(
        values: [0, 0, 1, 1, 0, 0],
        times: [
            0,
            NSNumber(value: safeStart / totalDuration),
            NSNumber(value: fadeInEnd / totalDuration),
            NSNumber(value: fadeOutStart / totalDuration),
            NSNumber(value: safeEnd / totalDuration),
            1,
        ],
        duration: totalDuration
    ), forKey: "visibility")
}

func caption(_ title: String, range: (start: Double, end: Double), number: Int) {
    let group = CALayer()
    group.frame = parent.bounds
    let marker = CALayer()
    marker.frame = CGRect(x: 152, y: 1732, width: 8, height: 94)
    marker.cornerRadius = 4
    marker.backgroundColor = green.cgColor
    group.addSublayer(marker)
    group.addSublayer(textLayer(
        String(format: "FILARY TOUR  ·  %02d", number),
        frame: CGRect(x: 184, y: 1810, width: 760, height: 34),
        size: 23,
        weight: .bold,
        color: green,
        alignment: .left
    ))
    group.addSublayer(textLayer(
        title,
        frame: CGRect(x: 184, y: 1715, width: 760, height: 100),
        size: 48,
        weight: .bold,
        color: ink,
        alignment: .left
    ))
    show(group, start: range.start, end: range.end)
    parent.addSublayer(group)
}

// Captions follow the edited timeline, not raw source time.
caption("Start with a clear overview.", range: (contentRanges[0].start, contentRanges[0].end), number: 1)
caption("Add the details once.", range: (contentRanges[1].start, contentRanges[2].end), number: 2)
caption("Save. Your stock updates instantly.", range: (contentRanges[2].end, contentRanges[3].start + 1.0), number: 3)
caption("Scan a label. Skip the typing.", range: (contentRanges[3].start + 1.0, contentRanges[4].end), number: 4)
caption("Recognize, review and add.", range: (contentRanges[5].start, contentRanges[6].end), number: 5)
caption("Know what is ready to print.", range: (contentRanges[7].start, contentRanges[7].end), number: 6)

let footer = textLayer(
    "FILARY  •  INVENTORY FOR IPHONE & IPAD",
    frame: CGRect(x: 90, y: 46, width: 900, height: 40),
    size: 21,
    weight: .semibold,
    color: muted
)
show(footer, start: introDuration - 0.2, end: outroStart + 0.2, fade: 0.45)
parent.addSublayer(footer)

func fullCard(start: Double, end: Double) -> CALayer {
    let card = CALayer()
    card.frame = parent.bounds
    let background = CAGradientLayer()
    background.frame = card.bounds
    background.colors = [
        NSColor(calibratedRed: 0.86, green: 0.975, blue: 0.91, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.97, green: 0.995, blue: 0.98, alpha: 1).cgColor,
    ]
    background.startPoint = CGPoint(x: 0.15, y: 0.9)
    background.endPoint = CGPoint(x: 0.85, y: 0.1)
    card.addSublayer(background)
    show(card, start: start, end: end, fade: 0.6)
    parent.addSublayer(card)
    return card
}

func addIcon(to layer: CALayer, frame: CGRect) {
    let iconPath = FileManager.default.currentDirectoryPath + "/assets/app-icon.webp"
    guard let image = NSImage(contentsOfFile: iconPath) else { return }
    let icon = CALayer()
    icon.frame = frame
    icon.contents = image
    icon.contentsGravity = .resizeAspect
    icon.cornerRadius = 40
    icon.masksToBounds = true
    layer.addSublayer(icon)
}

let intro = fullCard(start: 0, end: introDuration + 0.05)
addIcon(to: intro, frame: CGRect(x: 440, y: 1310, width: 200, height: 200))
intro.addSublayer(textLayer("FILARY", frame: CGRect(x: 90, y: 1190, width: 900, height: 58), size: 29, weight: .bold, color: green))
intro.addSublayer(textLayer(
    "Your filament.\nAlways under control.",
    frame: CGRect(x: 75, y: 830, width: 930, height: 310),
    size: 78,
    weight: .bold,
    color: ink
))
intro.addSublayer(textLayer(
    "A faster, clearer inventory for every workshop.",
    frame: CGRect(x: 100, y: 710, width: 880, height: 70),
    size: 34,
    weight: .medium,
    color: muted
))

let outro = fullCard(start: outroStart - 0.05, end: totalDuration)
addIcon(to: outro, frame: CGRect(x: 448, y: 1340, width: 184, height: 184))
outro.addSublayer(textLayer("FILARY", frame: CGRect(x: 90, y: 1228, width: 900, height: 58), size: 28, weight: .bold, color: green))
outro.addSublayer(textLayer(
    "A tidier workshop\nstarts here.",
    frame: CGRect(x: 70, y: 880, width: 940, height: 285),
    size: 80,
    weight: .bold,
    color: ink
))
outro.addSublayer(textLayer(
    "Filary · available on the App Store",
    frame: CGRect(x: 90, y: 770, width: 900, height: 70),
    size: 35,
    weight: .medium,
    color: muted
))

let price = CALayer()
price.frame = CGRect(x: 337, y: 625, width: 406, height: 86)
price.cornerRadius = 43
price.backgroundColor = green.cgColor
price.shadowColor = green.cgColor
price.shadowOpacity = 0.22
price.shadowRadius = 24
price.shadowOffset = CGSize(width: 0, height: -6)
price.addSublayer(textLayer(
    "5.99 €  ·  ONE-TIME PRO",
    frame: CGRect(x: 18, y: 17, width: 370, height: 52),
    size: 25,
    weight: .bold,
    color: NSColor.white
))
outro.addSublayer(price)

videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
    postProcessingAsVideoLayer: videoLayer,
    in: parent
)

try? FileManager.default.removeItem(at: output)
guard let exporter = AVAssetExportSession(
    asset: composition,
    presetName: AVAssetExportPresetHighestQuality
) else { fatalError("Cannot create exporter") }
exporter.outputURL = output
exporter.outputFileType = .mp4
exporter.videoComposition = videoComposition
exporter.shouldOptimizeForNetworkUse = true

let semaphore = DispatchSemaphore(value: 0)
exporter.exportAsynchronously { semaphore.signal() }
semaphore.wait()
guard exporter.status == .completed else {
    fatalError("Export failed: \(exporter.error?.localizedDescription ?? "unknown")")
}

print(String(format: "Created %.1f s professional web tour at %@", totalDuration, output.path))
