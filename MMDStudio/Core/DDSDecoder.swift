import Foundation

/// Minimal DDS decoder for the formats commonly found in MMD model rips:
/// uncompressed RGB(A), DXT1/BC1, DXT3/BC2 and DXT5/BC3. Only the top mip is
/// decoded, which is what the viewport needs.
enum MMDDDSDecoder {

    static func decode(_ data: Data) -> MMDTextureLibrary.DecodedImage? {
        let bytes = [UInt8](data)
        guard bytes.count >= 128, bytes[0] == 0x44, bytes[1] == 0x44, bytes[2] == 0x53, bytes[3] == 0x20 else {
            return nil
        }
        let height = Int(readU32(bytes, 12))
        let width = Int(readU32(bytes, 16))
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }

        let pfFlags = readU32(bytes, 80)
        let fourCC = String(bytes: bytes[84..<88], encoding: .ascii) ?? ""
        let rgbBits = Int(readU32(bytes, 88))
        let rMask = readU32(bytes, 92)
        let gMask = readU32(bytes, 96)
        let bMask = readU32(bytes, 100)
        let aMask = readU32(bytes, 104)

        var payloadOffset = 128
        var format = fourCC
        if fourCC == "DX10" {
            guard bytes.count >= 148 else { return nil }
            let dxgi = readU32(bytes, 128)
            payloadOffset = 148
            switch dxgi {
            case 71, 72: format = "DXT1"
            case 74, 75: format = "DXT3"
            case 77, 78: format = "DXT5"
            case 98, 99: format = "BC7"
            default: format = ""
            }
        }

        if format == "DXT1" || format == "DXT3" || format == "DXT5" || format == "BC7" {
            return decodeBlockCompressed(bytes, offset: payloadOffset,
                                         width: width, height: height, format: format)
        }

        // Uncompressed RGB/RGBA with channel masks.
        if pfFlags & 0x40 != 0, rgbBits == 24 || rgbBits == 32 {
            let bytesPerPixel = rgbBits / 8
            let pitch = max(width * bytesPerPixel, Int(readU32(bytes, 20)))
            guard payloadOffset + pitch * height <= bytes.count else { return nil }
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let src = payloadOffset + y * pitch + x * bytesPerPixel
                    let pixel = readU32(bytes, src)
                    let r = extract(pixel, mask: rMask, fallback: 0)
                    let g = extract(pixel, mask: gMask, fallback: 1)
                    let b = extract(pixel, mask: bMask, fallback: 2)
                    let a = aMask == 0 ? 255 : extract(pixel, mask: aMask, fallback: 3)
                    let dst = (y * width + x) * 4
                    pixels[dst + 0] = r
                    pixels[dst + 1] = g
                    pixels[dst + 2] = b
                    pixels[dst + 3] = a
                }
            }
            return MMDTextureLibrary.DecodedImage(data: pixels, width: width, height: height)
        }
        return nil
    }

    private static func decodeBlockCompressed(_ bytes: [UInt8], offset: Int,
                                              width: Int, height: Int,
                                              format: String) -> MMDTextureLibrary.DecodedImage? {
        let blockBytes = format == "DXT1" ? 8 : 16
        let blocksX = (width + 3) / 4
        let blocksY = (height + 3) / 4
        guard offset + blocksX * blocksY * blockBytes <= bytes.count else { return nil }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var cursor = offset
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                if format == "BC7" {
                    var block = [UInt8](repeating: 0, count: 64)
                    bytes.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        block.withUnsafeMutableBytes { out in
                            if let destination = out.baseAddress {
                                bcdec_bc7(base.advanced(by: cursor), destination, 16)
                            }
                        }
                    }
                    for py in 0..<4 {
                        for px in 0..<4 {
                            let x = bx * 4 + px
                            let y = by * 4 + py
                            guard x < width, y < height else { continue }
                            let src = (py * 4 + px) * 4
                            let dst = (y * width + x) * 4
                            pixels[dst + 0] = block[src + 0]
                            pixels[dst + 1] = block[src + 1]
                            pixels[dst + 2] = block[src + 2]
                            pixels[dst + 3] = block[src + 3]
                        }
                    }
                    cursor += 16
                    continue
                }
                let colorOffset = format == "DXT1" ? cursor : cursor + 8
                let colors = decodeColorBlock(bytes, offset: colorOffset)
                let alphaValues: [UInt8]
                if format == "DXT3" {
                    alphaValues = decodeExplicitAlpha(bytes, offset: cursor)
                } else if format == "DXT5" {
                    alphaValues = decodeInterpolatedAlpha(bytes, offset: cursor)
                } else {
                    alphaValues = colors.transparent ? [0, 0, 0, 0] : [255, 255, 255, 255]
                }

                for py in 0..<4 {
                    for px in 0..<4 {
                        let x = bx * 4 + px
                        let y = by * 4 + py
                        guard x < width, y < height else { continue }
                        let index = py * 4 + px
                        let color = colors.rgba[index]
                        let alpha = alphaValues[index]
                        let dst = (y * width + x) * 4
                        pixels[dst + 0] = color.0
                        pixels[dst + 1] = color.1
                        pixels[dst + 2] = color.2
                        pixels[dst + 3] = alpha
                    }
                }
                cursor += blockBytes
            }
        }
        return MMDTextureLibrary.DecodedImage(data: pixels, width: width, height: height)
    }

    private static func decodeColorBlock(_ bytes: [UInt8], offset: Int) -> (rgba: [(UInt8, UInt8, UInt8, UInt8)], transparent: Bool) {
        let c0 = readU16(bytes, offset)
        let c1 = readU16(bytes, offset + 2)
        let selectors = readU32(bytes, offset + 4)
        let color0 = expand565(c0)
        let color1 = expand565(c1)
        let transparent = c0 <= c1
        var palette: [(UInt8, UInt8, UInt8, UInt8)] = [color0, color1, color0, color1]
        if transparent {
            palette[2] = (UInt8((Int(color0.0) + Int(color1.0)) / 2),
                          UInt8((Int(color0.1) + Int(color1.1)) / 2),
                          UInt8((Int(color0.2) + Int(color1.2)) / 2), 255)
            palette[3] = (0, 0, 0, 0)
        } else {
            palette[2] = (UInt8((2 * Int(color0.0) + Int(color1.0)) / 3),
                          UInt8((2 * Int(color0.1) + Int(color1.1)) / 3),
                          UInt8((2 * Int(color0.2) + Int(color1.2)) / 3), 255)
            palette[3] = (UInt8((Int(color0.0) + 2 * Int(color1.0)) / 3),
                          UInt8((Int(color0.1) + 2 * Int(color1.1)) / 3),
                          UInt8((Int(color0.2) + 2 * Int(color1.2)) / 3), 255)
        }
        var result = [(UInt8, UInt8, UInt8, UInt8)]()
        result.reserveCapacity(16)
        for index in 0..<16 {
            let shift = UInt32(index * 2)
            let selector = (selectors >> shift) & 0x03
            result.append(palette[Int(selector)])
        }
        return (result, transparent)
    }

    private static func decodeExplicitAlpha(_ bytes: [UInt8], offset: Int) -> [UInt8] {
        var values = [UInt8](repeating: 255, count: 16)
        for index in 0..<8 {
            let byte = bytes[offset + index]
            values[index * 2] = (byte & 0x0F) * 17
            values[index * 2 + 1] = (byte >> 4) * 17
        }
        return values
    }

    private static func decodeInterpolatedAlpha(_ bytes: [UInt8], offset: Int) -> [UInt8] {
        let a0 = bytes[offset]
        let a1 = bytes[offset + 1]
        var palette = [UInt8](repeating: 0, count: 8)
        palette[0] = a0
        palette[1] = a1
        if a0 > a1 {
            for i in 2..<8 {
                palette[i] = UInt8((Int(a0) * (8 - i) + Int(a1) * (i - 1)) / 7)
            }
        } else {
            for i in 2..<6 {
                palette[i] = UInt8((Int(a0) * (6 - i) + Int(a1) * (i - 1)) / 5)
            }
            palette[6] = 0
            palette[7] = 255
        }
        var bits: UInt64 = 0
        for index in 0..<6 {
            bits |= UInt64(bytes[offset + 2 + index]) << UInt64(index * 8)
        }
        var values = [UInt8](repeating: 255, count: 16)
        for index in 0..<16 {
            let selector = Int((bits >> UInt64(index * 3)) & 0x7)
            values[index] = palette[selector]
        }
        return values
    }

    private static func expand565(_ value: UInt16) -> (UInt8, UInt8, UInt8, UInt8) {
        let r = UInt8((value >> 11) & 0x1F)
        let g = UInt8((value >> 5) & 0x3F)
        let b = UInt8(value & 0x1F)
        return (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2, 255)
    }

    private static func extract(_ value: UInt32, mask: UInt32, fallback: UInt8) -> UInt8 {
        guard mask != 0 else { return fallback }
        let shift = mask.trailingZeroBitCount
        let maxValue = mask >> shift
        let raw = (value & mask) >> shift
        guard maxValue > 0 else { return 0 }
        return UInt8(max(0, min(255, Int((Double(raw) / Double(maxValue) * 255).rounded()))))
    }

    private static func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
