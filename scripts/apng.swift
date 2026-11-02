// Builds an animated PNG from a folder of same-sized RGBA PNGs named <order>-<milliseconds>.png.
//   apng <frames folder> <output.png>
// The last frame is also the file's still image, outside the animation, for anything that can't play one.
// Each frame stores only what changed since the one before, and frames with nothing new extend the one before.
import Compression
import Foundation
import ImageIO

func fail(_ why: String) -> Never { print("apng: " + why); exit(1) }

/// Straight, not premultiplied, RGBA. Fully clear pixels all become the same clear.
func load(_ path: String) -> (width: Int, height: Int, pixels: [UInt32]) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let data = image.dataProvider?.data as Data?,
          image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.alphaInfo == .last else { fail("not 8-bit straight RGBA: \(path)") }
    var out = [UInt32](repeating: 0, count: image.width * image.height)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for y in 0..<image.height {
            for x in 0..<image.width {
                let p = raw.loadUnaligned(fromByteOffset: y * image.bytesPerRow + x * 4, as: UInt32.self)     // little-endian: A is the top byte
                out[y * image.width + x] = p >> 24 == 0 ? 0 : p
            }
        }
    }
    return (image.width, image.height, out)
}

let crcTable: [UInt32] = (0..<256).map { n in (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 } }

func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }

func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
    let named = Array(type.utf8) + body
    let crc = named.reduce(UInt32.max) { crcTable[Int(($0 ^ UInt32($1)) & 255)] ^ ($0 >> 8) } ^ .max
    return be(UInt32(body.count)) + named + be(crc)
}

/// A zlib stream around the system's deflate.
func zlib(_ data: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: data.count + data.count / 8 + 1024)
    let n = compression_encode_buffer(&out, out.count, data, data.count, nil, COMPRESSION_ZLIB)
    guard n > 0 else { fail("deflate failed") }
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    return [0x78, 0x01] + out[0..<n] + be(b << 16 | a)
}

func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
    let p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
    return pa <= pb && pa <= pc ? a : pb <= pc ? b : c
}

/// PNG scanlines for a rectangle, each with whichever filter leaves the smallest sum.
func scanlines(_ px: [UInt32], stride: Int, _ w: Int, _ h: Int, adaptive: Bool) -> [UInt8] {
    let row = w * 4
    var out = [UInt8](); out.reserveCapacity((row + 1) * h)
    var up = [UInt8](repeating: 0, count: row), line = up
    var best = up, trial = up
    for y in 0..<h {
        for x in 0..<w { let p = px[y * stride + x]; for k in 0..<4 { line[x * 4 + k] = UInt8(p >> (8 * UInt32(k)) & 255) } }
        var bestType: UInt8 = 0, bestCost = Int.max
        for type in adaptive ? [0, 1, 2, 4] as [UInt8] : [0] {
            var cost = 0
            for i in 0..<row {
                let v = Int(line[i]), a = i >= 4 ? Int(line[i - 4]) : 0, b = Int(up[i]), c = i >= 4 ? Int(up[i - 4]) : 0
                let f: Int
                switch type {
                case 1: f = v - a
                case 2: f = v - b
                case 4: f = v - paeth(a, b, c)
                default: f = v
                }
                let byte = UInt8(truncatingIfNeeded: f)
                trial[i] = byte
                cost += byte < 128 ? Int(byte) : 256 - Int(byte)
            }
            if cost < bestCost { bestCost = cost; bestType = type; swap(&best, &trial) }
        }
        out.append(bestType)
        out += best
        swap(&up, &line)
    }
    return out
}

func smallest(_ px: [UInt32], stride: Int, _ w: Int, _ h: Int) -> [UInt8] {
    let a = zlib(scanlines(px, stride: stride, w, h, adaptive: true)), b = zlib(scanlines(px, stride: stride, w, h, adaptive: false))
    return a.count <= b.count ? a : b
}

guard CommandLine.arguments.count == 3 else { fail("usage: apng <frames folder> <output.png>") }
let folder = CommandLine.arguments[1]
let names = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { $0.hasSuffix(".png") }.sorted() ?? []
guard let last = names.last else { fail("no frames") }
let poster = load(folder + "/" + last)
let (W, H) = (poster.width, poster.height)

struct Part { var x, y, w, h: Int; var over: Bool; var data: [UInt8]; var ms: Int }
var parts: [Part] = []
var canvas = [UInt32](repeating: 0, count: W * H)

for name in names {
    let frame = load(folder + "/" + name)
    guard frame.width == W, frame.height == H else { fail("\(name) is a different size") }
    let ms = Int(name.dropFirst(5).dropLast(4)) ?? 66
    var x0 = W, x1 = -1, y0 = H, y1 = -1, opaque = true
    for y in 0..<H {
        for x in 0..<W where frame.pixels[y * W + x] != canvas[y * W + x] {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            if frame.pixels[y * W + x] >> 24 != 255 { opaque = false }
        }
    }
    if x1 < 0, !parts.isEmpty { parts[parts.count - 1].ms += ms; continue }
    if parts.isEmpty { (x0, x1, y0, y1) = (0, W - 1, 0, H - 1); opaque = false }    // the first frame fills the canvas
    let (w, h) = (x1 - x0 + 1, y1 - y0 + 1)
    var sub = [UInt32](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y + y0) * W + x + x0
            // Where only solid pixels changed, what didn't change can stay clear and be drawn over the last frame.
            sub[y * w + x] = opaque && frame.pixels[i] == canvas[i] ? 0 : frame.pixels[i]
        }
    }
    parts.append(Part(x: x0, y: y0, w: w, h: h, over: opaque, data: smallest(sub, stride: w, w, h), ms: ms))
    canvas = frame.pixels
}

var file: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
file += chunk("IHDR", be(UInt32(W)) + be(UInt32(H)) + [8, 6, 0, 0, 0])
file += chunk("sRGB", [0])
file += chunk("acTL", be(UInt32(parts.count)) + be(0))
file += chunk("IDAT", smallest(poster.pixels, stride: W, W, H))
var sequence: UInt32 = 0
for p in parts {
    let delay = UInt16(min(p.ms, 65535))
    file += chunk("fcTL", be(sequence) + be(UInt32(p.w)) + be(UInt32(p.h)) + be(UInt32(p.x)) + be(UInt32(p.y))
                  + [UInt8(delay >> 8), UInt8(delay & 255), 0x03, 0xE8, 0, p.over ? 1 : 0])
    sequence += 1
    file += chunk("fdAT", be(sequence) + p.data)
    sequence += 1
}
file += chunk("IEND", [])
FileManager.default.createFile(atPath: CommandLine.arguments[2], contents: Data(file))
print("\(W)x\(H), \(parts.count) frames, \(parts.reduce(0) { $0 + $1.ms }) ms, \(file.count / 1024) KB")
