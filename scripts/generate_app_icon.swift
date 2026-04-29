import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: swift generate_app_icon.swift /path/to/source.png /path/to/AppIcon.icns\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let destinationURL = URL(fileURLWithPath: arguments[2])
let fileManager = FileManager.default
let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent("NetPulseIcon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = temporaryDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fputs("Failed to load source image at \(sourceURL.path)\n", stderr)
    exit(1)
}

try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let sourceSize = sourceImage.size
    let scale = min(rect.width / sourceSize.width, rect.height / sourceSize.height)
    let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    let drawRect = NSRect(
        x: (rect.width - drawSize.width) / 2,
        y: (rect.height - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    sourceImage.draw(
        in: drawRect,
        from: NSRect(origin: .zero, size: sourceSize),
        operation: .copy,
        fraction: 1.0
    )

    image.unlockFocus()

    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "NetPulseIcon", code: 1)
    }

    try pngData.write(to: iconsetURL.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", destinationURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "NetPulseIcon", code: Int(process.terminationStatus))
}

try? fileManager.removeItem(at: temporaryDirectory)
