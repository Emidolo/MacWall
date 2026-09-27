import Compression
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacWallKit

// MARK: - Fixture writers (little-endian, same layout the decoders read)

private extension Data {
    mutating func u32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func lstr(_ s: String) { u32(UInt32(s.utf8.count)); append(contentsOf: s.utf8) }
    mutating func cstr(_ s: String) { append(contentsOf: s.utf8); append(0) }
}

private func pkg(_ files: [(String, Data)]) -> Data {
    var d = Data()
    d.lstr("PKGV0019")
    d.u32(UInt32(files.count))
    var offset: UInt32 = 0
    for (name, body) in files {
        d.lstr(name)
        d.u32(offset)
        d.u32(UInt32(body.count))
        offset += UInt32(body.count)
    }
    files.forEach { d.append($0.1) }
    return d
}

private func tex(format: Int32, texSize: (Int, Int), imageSize: (Int, Int), container: String = "TEXB0003",
                 freeImage: Int32 = -1, mip: Data, mipSize: (Int, Int)? = nil, lz4: Bool = false) -> Data {
    var d = Data()
    d.cstr("TEXV0005"); d.cstr("TEXI0001")
    d.i32(format); d.u32(0)
    d.u32(UInt32(texSize.0)); d.u32(UInt32(texSize.1)); d.u32(UInt32(imageSize.0)); d.u32(UInt32(imageSize.1))
    d.u32(0)
    d.cstr(container)
    d.u32(1)                                   // image count
    if container == "TEXB0003" || container == "TEXB0004" { d.i32(freeImage) }
    if container == "TEXB0004" { d.u32(0) }    // isVideoMp4
    d.u32(1)                                   // mipmap count
    let (w, h) = mipSize ?? texSize
    d.u32(UInt32(w)); d.u32(UInt32(h))
    var body = mip
    if container != "TEXB0001" {
        if lz4 {
            var out = [UInt8](repeating: 0, count: mip.count + 64)
            let n = mip.withUnsafeBytes { compression_encode_buffer(&out, out.count, $0.bindMemory(to: UInt8.self).baseAddress!, mip.count, nil, COMPRESSION_LZ4_RAW) }
            body = Data(out[0..<n])
        }
        d.u32(lz4 ? 1 : 0); d.u32(UInt32(mip.count))
    }
    d.u32(UInt32(body.count))
    d.append(body)
    return d
}

private func pixel(_ t: TEXTexture, _ x: Int, _ y: Int) -> [UInt8] {
    let i = (y * t.width + x) * 4
    return Array(t.rgba[i..<i + 4])
}

// MARK: - PKG

@Test func unpacksPKG() throws {
    let a = pkg([("scene.json", Data("{}".utf8)), ("materials/a.tex", Data([1, 2, 3]))])
    let p = try PKGArchive(data: a)
    #expect(p.version == "PKGV0019")
    #expect(p.names == ["scene.json", "materials/a.tex"])
    #expect(p["scene.json"] == Data("{}".utf8))
    #expect(p["materials/a.tex"] == Data([1, 2, 3]))
    #expect(p["missing"] == nil)
}

@Test func rejectsTruncatedPKG() {
    let a = pkg([("scene.json", Data("{}".utf8))])
    #expect(throws: FormatError.self) { try PKGArchive(data: a.prefix(a.count - 1)) }
    #expect(throws: FormatError.self) { try PKGArchive(data: Data("nope".utf8)) }
}

// MARK: - TEX

@Test func decodesRGBA8888WithPadding() throws {
    // 4x2 texture holding a 3x2 image.
    let px = Data((0..<8).flatMap { i in [UInt8(i), 10, 20, 255] })
    let t = try TEXTexture(data: tex(format: 0, texSize: (4, 2), imageSize: (3, 2), mip: px))
    #expect((t.width, t.height) == (4, 2))
    #expect((t.imageWidth, t.imageHeight) == (3, 2))
    #expect(pixel(t, 1, 1) == [5, 10, 20, 255])
}

@Test func decodesLZ4() throws {
    let px = Data(repeating: 7, count: 16 * 16 * 4)
    let t = try TEXTexture(data: tex(format: 0, texSize: (16, 16), imageSize: (16, 16), mip: px, lz4: true))
    #expect(t.rgba == px)
}

@Test func decodesTEXB0001AndTEXB0004Containers() throws {
    let px = Data([1, 2, 3, 4])
    #expect(try TEXTexture(data: tex(format: 0, texSize: (1, 1), imageSize: (1, 1), container: "TEXB0001", mip: px)).rgba == px)
    #expect(try TEXTexture(data: tex(format: 0, texSize: (1, 1), imageSize: (1, 1), container: "TEXB0004", mip: px)).rgba == px)
}

@Test func decodesR8AndRG88() throws {
    let r8 = try TEXTexture(data: tex(format: 9, texSize: (2, 1), imageSize: (2, 1), mip: Data([0, 200])))
    #expect(pixel(r8, 1, 0) == [200, 200, 200, 255])
    let rg = try TEXTexture(data: tex(format: 8, texSize: (1, 1), imageSize: (1, 1), mip: Data([90, 40])))
    #expect(pixel(rg, 0, 0) == [90, 90, 90, 40])
}

@Test func decodesDXT1() throws {
    // c0 = pure red (565: 0xF800), c1 = pure blue (0x001F); c0 > c1 → 4-colour mode.
    // Row 0 indices: 0,1,2,3 → red, blue, 2/3 red + 1/3 blue, 1/3 red + 2/3 blue. Other rows index 0.
    let block = Data([0x00, 0xF8, 0x1F, 0x00, 0b1110_0100, 0, 0, 0])
    let t = try TEXTexture(data: tex(format: 7, texSize: (4, 4), imageSize: (4, 4), mip: block))
    #expect(pixel(t, 0, 0) == [255, 0, 0, 255])
    #expect(pixel(t, 1, 0) == [0, 0, 255, 255])
    #expect(pixel(t, 2, 0) == [170, 0, 85, 255])
    #expect(pixel(t, 3, 0) == [85, 0, 170, 255])
    #expect(pixel(t, 3, 3) == [255, 0, 0, 255])
}

@Test func decodesDXT1PunchThroughAlpha() throws {
    // c0 <= c1 → 3-colour mode, index 3 is transparent black.
    let block = Data([0x1F, 0x00, 0x00, 0xF8, 0b1100_0000, 0, 0, 0])
    let t = try TEXTexture(data: tex(format: 7, texSize: (4, 4), imageSize: (4, 4), mip: block))
    #expect(pixel(t, 3, 0) == [0, 0, 0, 0])
    #expect(pixel(t, 0, 0) == [0, 0, 255, 255])
}

@Test func decodesDXT5Alpha() throws {
    // Alpha a0=255, a1=0 (8-value mode); first pixel index 1 (a1=0), second index 0 (255). Colour: white.
    var block = Data([255, 0, 0b0000_0001, 0, 0, 0, 0, 0])
    block.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0])
    let t = try TEXTexture(data: tex(format: 4, texSize: (4, 4), imageSize: (4, 4), mip: block))
    #expect(pixel(t, 0, 0) == [255, 255, 255, 0])
    #expect(pixel(t, 1, 0) == [255, 255, 255, 255])
}

@Test func decodesDXT3Alpha() throws {
    var block = Data([0x0F, 0, 0, 0, 0, 0, 0, 0])      // pixel 0 alpha 0xF → 255, pixel 1 → 0
    block.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0])
    let t = try TEXTexture(data: tex(format: 6, texSize: (4, 4), imageSize: (4, 4), mip: block))
    #expect(pixel(t, 0, 0)[3] == 255)
    #expect(pixel(t, 1, 0)[3] == 0)
}

@Test func decodesEmbeddedPNG() throws {
    let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let png = NSMutableData()
    let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    let t = try TEXTexture(data: tex(format: 0, texSize: (2, 2), imageSize: (2, 2), freeImage: 13, mip: png as Data))
    #expect((t.width, t.height) == (2, 2))
    #expect(pixel(t, 1, 1) == [0, 255, 0, 255])
}

@Test func rejectsBadTEX() {
    #expect(throws: FormatError.self) { try TEXTexture(data: Data("TEXV0005\0garbage".utf8)) }
    let px = Data([1, 2, 3, 4])
    let good = tex(format: 0, texSize: (1, 1), imageSize: (1, 1), mip: px)
    #expect(throws: FormatError.self) { try TEXTexture(data: good.prefix(good.count - 2)) }
    #expect(throws: FormatError.self) { try TEXTexture(data: tex(format: 42, texSize: (1, 1), imageSize: (1, 1), mip: px)) }
    let mp4 = Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8) + Data(count: 20)
    #expect(throws: FormatError.unsupported("video texture")) { try TEXTexture(data: tex(format: 0, texSize: (4, 2), imageSize: (4, 2), mip: mp4)) }
}
