// make-app-icon.swift — turn a flat PNG of the app icon into a macOS icon set.
//
//   xcrun swift Scripts/make-app-icon.swift <source.png> <AppIcon.appiconset>
//
// The artwork arrives as a rounded square drawn on an opaque white background.
// Shipping that as-is puts white corners in the Dock, so this:
//   1. flood-fills the white background from the border (only white *connected*
//      to the edge goes, so the white cloud and tick inside survive),
//   2. measures the artwork's own corner radius from its top row,
//   3. re-masks it with a rounded rect, which removes the anti-aliased white
//      halo that thresholding alone leaves behind,
//   4. draws it at 824/1024 of the canvas — Apple's macOS proportions since
//      Big Sur — and writes every size the asset catalog asks for.

import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: make-app-icon.swift <source.png> <AppIcon.appiconset>\n", stderr)
    exit(2)
}
let sourceURL = URL(filePath: arguments[1])
let setURL = URL(filePath: arguments[2])

guard let image = NSImage(contentsOf: sourceURL),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("could not read \(sourceURL.path)\n", stderr)
    exit(1)
}

let width = source.width, height = source.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("no bitmap context\n", stderr)
    exit(1)
}
context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

// MARK: - 1. Flood-fill the white background inwards from the border

func isWhite(_ index: Int) -> Bool {
    pixels[index] > 244 && pixels[index + 1] > 244 && pixels[index + 2] > 244
}

var isBackground = [Bool](repeating: false, count: width * height)
var queue: [Int] = []
for x in 0..<width {
    for y in [0, height - 1] { queue.append(y * width + x) }
}
for y in 0..<height {
    for x in [0, width - 1] { queue.append(y * width + x) }
}

while let point = queue.popLast() {
    guard !isBackground[point], isWhite(point * 4) else { continue }
    isBackground[point] = true
    let x = point % width, y = point / width
    if x > 0 { queue.append(point - 1) }
    if x < width - 1 { queue.append(point + 1) }
    if y > 0 { queue.append(point - width) }
    if y < height - 1 { queue.append(point + width) }
}

// MARK: - 2. The artwork's bounding box and corner radius

var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where !isBackground[y * width + x] {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX else {
    fputs("the whole image looks like background\n", stderr)
    exit(1)
}
let artwork = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)

// At the artwork's topmost row the flat edge runs from minX+radius to
// maxX-radius, so the first opaque pixel in that row gives the radius.
var radius = 0
var scanRow = minY
// A hair below the very top, where anti-aliasing has settled.
scanRow = min(minY + 2, height - 1)
for x in minX...maxX where !isBackground[scanRow * width + x] {
    radius = x - minX
    break
}
let radiusFraction = Double(radius) / artwork.width
print(String(
    format: "artwork %.0fx%.0f at (%.0f,%.0f) · corner radius %d px (%.1f%%)",
    artwork.width, artwork.height, artwork.minX, artwork.minY, radius, radiusFraction * 100
))

// MARK: - 3. Mask the artwork with its own rounded rect

// Apple's shape is a squircle; a circular-corner rounded rect at the measured
// radius is within a pixel or two at icon sizes, and masking is safe in both
// directions — anything outside the mask (including halo) simply goes.
let cropped = CGRect(x: 0, y: 0, width: artwork.width, height: artwork.height)
guard let opaque = context.makeImage()?.cropping(to: artwork) else {
    fputs("could not crop\n", stderr)
    exit(1)
}

/// Apple's shape, not the artwork's: 185/824 on the macOS icon grid. The
/// source art is a little rounder (measured above), and a Dock of squircles
/// with one rounder tile looks off. Masking tighter than the art also trims
/// the corners to the platform shape rather than leaving the art's own.
let appleRadiusFraction = 185.0 / 824.0

/// The art's outermost ring is anti-aliased against the white background it
/// arrived on. Clipping alone leaves that as a pale halo, so the art is drawn
/// very slightly larger than the clip and the ring falls outside it.
let overfillFraction = 0.014

func render(size: Int) -> CGImage? {
    guard let canvas = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    canvas.interpolationQuality = .high
    canvas.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // 824/1024 of the canvas, centred: the macOS app icon grid.
    let inset = (Double(size) * (1.0 - 824.0 / 1024.0)) / 2.0
    let target = CGRect(x: inset, y: inset, width: Double(size) - inset * 2, height: Double(size) - inset * 2)

    let corner = target.width * appleRadiusFraction
    canvas.addPath(CGPath(roundedRect: target, cornerWidth: corner, cornerHeight: corner, transform: nil))
    canvas.clip()

    let overfill = target.width * overfillFraction
    canvas.draw(opaque, in: target.insetBy(dx: -overfill, dy: -overfill))
    return canvas.makeImage()
}

// MARK: - 4. Write every size the catalog asks for

func write(_ image: CGImage, to url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: image.width, height: image.height)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

struct Entry {
    let size: Int
    let scale: Int
    var pixels: Int { size * scale }
    var filename: String { "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png" }
}

let entries = [16, 32, 128, 256, 512].flatMap { size in
    [Entry(size: size, scale: 1), Entry(size: size, scale: 2)]
}

var images: [[String: String]] = []
for entry in entries {
    guard let rendered = render(size: entry.pixels) else {
        fputs("could not render \(entry.pixels)px\n", stderr)
        exit(1)
    }
    try write(rendered, to: setURL.appending(path: entry.filename))
    images.append([
        "idiom": "mac",
        "scale": "\(entry.scale)x",
        "size": "\(entry.size)x\(entry.size)",
        "filename": entry.filename,
    ])
    print("  wrote \(entry.filename) (\(entry.pixels)px)")
}

// A 1024 master for eyeballing the result. Written next to the source art
// rather than inside the asset catalog, where a file belonging to no image set
// makes Xcode complain about unassigned children.
if let master = render(size: 1024) {
    try write(master, to: sourceURL.deletingLastPathComponent().appending(path: "app-icon-1024.png"))
}

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: setURL.appending(path: "Contents.json"))
print("==> wrote \(entries.count) icons and Contents.json")
