#!/usr/bin/env swift
// Builds Narengi/Assets.xcassets/AppIcon.appiconset from assets/fruit.png.
// Every size is drawn straight from the source image (never from another size) and the artwork is centred in a
// square canvas with the margin macOS icons conventionally leave.
//
// Usage: scripts/make-icon.swift [source.png]
import AppKit
import CoreGraphics
import Foundation
import ImageIO

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : root.appendingPathComponent("assets/fruit.png").path)
let set = root.appendingPathComponent("Narengi/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), let art = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    FileHandle.standardError.write(Data("error: cannot read \(source.path)\n".utf8)); exit(1)
}
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

/// Share of the canvas the artwork may fill (macOS icons keep a margin around the artwork).
let fill = 0.82

func render(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let canvas = Double(pixels)
    let scale = canvas * fill / Double(max(art.width, art.height))
    let w = Double(art.width) * scale, h = Double(art.height) * scale
    context.draw(art, in: CGRect(x: (canvas - w) / 2, y: (canvas - h) / 2, width: w, height: h))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

struct Slot { let points: Int; let scale: Int }
let slots = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }

var images: [[String: String]] = []
for slot in slots {
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
    try render(pixels: slot.points * slot.scale).write(to: set.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.points)x\(slot.points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: set.appendingPathComponent("Contents.json"))
try Data("{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n".utf8).write(to: set.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(set.path)")
