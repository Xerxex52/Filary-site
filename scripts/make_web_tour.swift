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
let introDuration = 4.8
let outroDuration = 5.4
let sourceDuration = CMTimeGetSeconds(asset.duration)
let frame = 1.0 / 30.0

let composition = AVMutableComposition()
guard let track = composition.addMutableTrack(
    withMediaType: .video,
    preferredTrackID: kCMPersistentTrackID_Invalid
) else { fatalError("Cannot create video track") }

func insert(_ start: Double, _ duration: Double, at cursor: CMTime) throws {
    try track.insertTimeRange(
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        ),
        of: source,
        at: cursor
    )
}

func freeze(_ instant: Double, duration: Double, at cursor: CMTime) throws {
    try insert(instant, frame, at: cursor)
    track.scaleTimeRange(
        CMTimeRange(start: cursor, duration: CMTime(seconds: frame, preferredTimescale: 600)),
        toDuration: CMTime(seconds: duration, preferredTimescale: 600)
    )
}

try freeze(0, duration: introDuration, at: .zero)
let contentStart = CMTime(seconds: introDuration, preferredTimescale: 600)
try insert(0, sourceDuration, at: contentStart)
let outroStart = introDuration + sourceDuration
try freeze(max(0, sourceDuration - frame), duration: outroDuration,
           at: CMTime(seconds: outroStart, preferredTimescale: 600))

let totalDuration = CMTimeGetSeconds(composition.duration)

let instruction = AVMutableVideoCompositionInstruction()
instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
let size = source.naturalSize
let scale = min(renderSize.width / size.width, renderSize.height / size.height)
let x = (renderSize.width - size.width * scale) / 2
let y = (renderSize.height - size.height * scale) / 2
layerInstruction.setTransform(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: x / scale, y: y / scale), at: .zero)
instruction.layerInstructions = [layerInstruction]

let videoComposition = AVMutableVideoComposition()
videoComposition.renderSize = renderSize
videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
videoComposition.instructions = [instruction]

let parent = CALayer()
parent.frame = CGRect(origin: .zero, size: renderSize)
parent.backgroundColor = NSColor(calibratedRed: 0.027, green: 0.063, blue: 0.051, alpha: 1).cgColor
let videoLayer = CALayer()
videoLayer.frame = parent.bounds
parent.addSublayer(videoLayer)

let green = NSColor(calibratedRed: 0.384, green: 0.906, blue: 0.620, alpha: 1)
let ink = NSColor(calibratedWhite: 0.97, alpha: 1)
let muted = NSColor(calibratedRed: 0.69, green: 0.76, blue: 0.72, alpha: 1)

func textLayer(_ text: String, frame: CGRect, size: CGFloat, weight: NSFont.Weight,
               color: NSColor = ink) -> CALayer {
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
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    let attributed = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ])
    let height = attributed.boundingRect(
        with: frame.size,
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height
    attributed.draw(in: CGRect(
        x: 0,
        y: max(0, (frame.height - height) / 2),
        width: frame.width,
        height: min(frame.height, height + 8)
    ))
    NSGraphicsContext.restoreGraphicsState()
    let layer = CALayer()
    layer.frame = frame
    layer.contents = bitmap.cgImage
    layer.contentsGravity = .resize
    return layer
}

func opacityAnimation(values: [NSNumber], times: [NSNumber], duration: Double) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    animation.values = values
    animation.keyTimes = times
    animation.duration = duration
    animation.beginTime = AVCoreAnimationBeginTimeAtZero
    animation.isRemovedOnCompletion = false
    animation.fillMode = .both
    return animation
}

func fullCard(start: Double, duration: Double, fadeIn: Bool, fadeOut: Bool) -> CALayer {
    let card = CALayer()
    card.frame = parent.bounds
    card.backgroundColor = NSColor(calibratedRed: 0.027, green: 0.063, blue: 0.051, alpha: 1).cgColor
    let halo = CALayer()
    halo.frame = CGRect(x: -220, y: 900, width: 1500, height: 1100)
    halo.cornerRadius = 550
    halo.backgroundColor = green.withAlphaComponent(0.11).cgColor
    card.addSublayer(halo)
    let startKey = start / totalDuration
    let endKey = (start + duration) / totalDuration
    let fade = 0.65 / totalDuration
    var values: [NSNumber] = [0, 0]
    var times: [NSNumber] = [0, NSNumber(value: startKey)]
    if fadeIn {
        values += [1]
        times += [NSNumber(value: min(endKey, startKey + fade))]
    } else {
        values[1] = 1
    }
    if fadeOut {
        values += [1, 0, 0]
        times += [NSNumber(value: max(startKey, endKey - fade)), NSNumber(value: endKey), 1]
    } else {
        values += [1, 1]
        times += [NSNumber(value: endKey), 1]
    }
    card.add(opacityAnimation(values: values, times: times, duration: totalDuration), forKey: "visibility")
    parent.addSublayer(card)
    return card
}

let intro = fullCard(start: 0, duration: introDuration, fadeIn: false, fadeOut: true)
intro.addSublayer(textLayer("FILARY", frame: CGRect(x: 90, y: 1515, width: 900, height: 68), size: 30, weight: .bold, color: green))
intro.addSublayer(textLayer("Your filament.\nAlways under control.", frame: CGRect(x: 70, y: 900, width: 940, height: 330), size: 78, weight: .bold))
intro.addSublayer(textLayer("Inventory for iPhone & iPad", frame: CGRect(x: 90, y: 770, width: 900, height: 72), size: 38, weight: .medium, color: muted))

struct Caption { let start: Double; let end: Double; let text: String }
let captions = [
    Caption(start: 0.2, end: 5.4, text: "See your stock at a glance"),
    Caption(start: 5.4, end: 12.6, text: "Add every detail once"),
    Caption(start: 12.6, end: 18.2, text: "Find and update spools in seconds"),
    Caption(start: 18.2, end: 24.4, text: "Scan labels. Skip the typing."),
    Caption(start: 24.4, end: sourceDuration, text: "Know what remains before you print"),
]

for caption in captions {
    let pill = CALayer()
    pill.frame = CGRect(x: 92, y: 1495, width: 896, height: 116)
    pill.cornerRadius = 34
    pill.backgroundColor = NSColor(calibratedRed: 0.025, green: 0.055, blue: 0.045, alpha: 0.91).cgColor
    pill.borderWidth = 1
    pill.borderColor = green.withAlphaComponent(0.26).cgColor
    pill.addSublayer(textLayer(caption.text, frame: CGRect(x: 28, y: 27, width: 840, height: 62), size: 35, weight: .semibold))
    let start = (introDuration + caption.start) / totalDuration
    let end = (introDuration + caption.end) / totalDuration
    let fade = 0.22 / totalDuration
    pill.add(opacityAnimation(
        values: [0, 0, 1, 1, 0, 0],
        times: [0, NSNumber(value: start), NSNumber(value: start + fade), NSNumber(value: max(start + fade, end - fade)), NSNumber(value: end), 1],
        duration: totalDuration
    ), forKey: "visibility")
    parent.addSublayer(pill)
}

let outro = fullCard(start: outroStart, duration: outroDuration, fadeIn: true, fadeOut: false)
outro.addSublayer(textLayer("A tidier workshop\nstarts here.", frame: CGRect(x: 70, y: 930, width: 940, height: 260), size: 76, weight: .bold))
outro.addSublayer(textLayer("Filary · on the App Store", frame: CGRect(x: 90, y: 790, width: 900, height: 78), size: 39, weight: .medium, color: muted))
let badge = CALayer()
badge.frame = CGRect(x: 355, y: 635, width: 370, height: 74)
badge.cornerRadius = 37
badge.backgroundColor = green.cgColor
badge.addSublayer(textLayer("5.99 € · ONE TIME", frame: CGRect(x: 12, y: 17, width: 346, height: 45), size: 26, weight: .bold, color: NSColor(calibratedRed: 0.015, green: 0.07, blue: 0.04, alpha: 1)))
outro.addSublayer(badge)

videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
    postProcessingAsVideoLayer: videoLayer,
    in: parent
)

try? FileManager.default.removeItem(at: output)
guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
    fatalError("Cannot create exporter")
}
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
print(String(format: "Created %.1f s web tour at %@", totalDuration, output.path))
