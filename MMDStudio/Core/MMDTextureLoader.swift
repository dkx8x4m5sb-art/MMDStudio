import Foundation
import Metal
import CoreGraphics
import ImageIO

/// Loads MMD textures (PNG/JPG/BMP/TGA) and keeps them in a cache.
final class MMDTextureLibrary {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private var cache: [String: MTLTexture] = [:]

    let whiteTexture: MTLTexture
    let blackTexture: MTLTexture
    let toonRamps: [MTLTexture]

    private(set) var missingTextures: Set<String> = []
    private var loggedMissing: Set<String> = []
    var missingCount: Int { missingTextures.count }
    var missingTextureNames: [String] { missingTextures.sorted() }

    func clearCache() {
        cache.removeAll(keepingCapacity: true)
        missingTextures.removeAll(keepingCapacity: true)
        loggedMissing.removeAll(keepingCapacity: true)
        directoryIndexCache.removeAll(keepingCapacity: true)
    }

    init(device: MTLDevice, commandQueue: MTLCommandQueue?) {
        self.device = device
        self.commandQueue = commandQueue
        self.whiteTexture = MMDTextureLibrary.makeSolidTexture(device: device, color: (255, 255, 255, 255))
        self.blackTexture = MMDTextureLibrary.makeSolidTexture(device: device, color: (0, 0, 0, 255))
        self.toonRamps = MMDTextureLibrary.makeToonRamps(device: device)
    }

    func load(path: String, baseDirectory: URL?, fallbackRoot: URL? = nil) -> MTLTexture {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return whiteTexture }

        guard let url = resolveURL(path: normalized, baseDirectory: baseDirectory, fallbackRoot: fallbackRoot) else {
            recordMissing(normalized, baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
            return whiteTexture
        }
        // Cache by the actual file, not by the PMX-relative string. Two models
        // in one archive may reference the same relative name but resolve to
        // different files.
        let key = url.standardizedFileURL.path.lowercased()
        if let cached = cache[key] { return cached }
        guard let pixels = MMDTextureLibrary.decodeImageFile(url: url) else {
            recordMissing(normalized, baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
            MMDLog.shared.warning("Texture decode failed: \(normalized) at \(url.path)")
            return whiteTexture
        }
        guard let texture = makeTexture(pixels.data, width: pixels.width, height: pixels.height) else {
            recordMissing(normalized, baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
            MMDLog.shared.warning("Texture upload failed: \(normalized) \(pixels.width)x\(pixels.height)")
            return whiteTexture
        }
        cache[key] = texture
        return texture
    }

    /// Loads a standalone image file (for example the scene backdrop) with
    /// the same decode and upload path used by model textures.
    func loadFileTexture(url: URL) -> MTLTexture? {
        let key = url.standardizedFileURL.path.lowercased()
        if let cached = cache[key] { return cached }
        guard let pixels = MMDTextureLibrary.decodeImageFile(url: url),
              let texture = makeTexture(pixels.data, width: pixels.width, height: pixels.height) else {
            return nil
        }
        cache[key] = texture
        return texture
    }

    func embeddedOrFallback(index: Int, model: PMXModel, baseDirectory: URL?, fallbackRoot: URL? = nil) -> MTLTexture {
        guard index >= 0 && index < model.textures.count else { return whiteTexture }
        return load(path: model.textures[index], baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
    }

    func toonTexture(for material: PMXMaterial, model: PMXModel, baseDirectory: URL?, fallbackRoot: URL? = nil) -> MTLTexture {
        if material.toonReference == 1 {
            let index = material.toonValue
            if index >= 0 && index < toonRamps.count { return toonRamps[index] }
            return toonRamps.first ?? whiteTexture
        }
        if material.toonValue >= 0 && material.toonValue < model.textures.count {
            let texture = load(path: model.textures[material.toonValue], baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
            return texture
        }
        return whiteTexture
    }

    // MARK: - Path resolution

    private var directoryIndexCache: [String: [String: URL]] = [:]

    private func recordMissing(_ path: String, baseDirectory: URL?, fallbackRoot: URL?) {
        missingTextures.insert(path)
        let key = "\(baseDirectory?.path ?? "")|\(fallbackRoot?.path ?? "")|\(path.lowercased())"
        guard loggedMissing.insert(key).inserted else { return }
        let roots = [baseDirectory?.path, fallbackRoot?.path].compactMap { $0 }.joined(separator: " | ")
        MMDLog.shared.warning("Missing texture: \(path); roots=\(roots)")
    }

    private func resolveURL(path: String, baseDirectory: URL?, fallbackRoot: URL?) -> URL? {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "//", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if normalized.contains("%"), let decoded = normalized.removingPercentEncoding {
            normalized = decoded
        }
        guard !normalized.isEmpty else { return nil }

        let roots = [baseDirectory, fallbackRoot].compactMap { $0 }
        for root in roots {
            if let url = resolve(path: normalized, in: root) { return url }
        }
        // Exporters often place the PMX in a subfolder such as
        // "Model/Model.pmx" while the Texture folder sits one level above.
        // Search the immediate parent and grandparent as a rescue.
        if let baseDirectory {
            var parent = baseDirectory.deletingLastPathComponent()
            for _ in 0..<2 {
                if let url = resolve(path: normalized, in: parent) { return url }
                parent = parent.deletingLastPathComponent()
            }
        }
        if baseDirectory == nil, fallbackRoot == nil {
            let exact = URL(fileURLWithPath: normalized)
            if FileManager.default.fileExists(atPath: exact.path) { return exact }
        }
        return nil
    }

    private func resolve(path: String, in baseDirectory: URL) -> URL? {
        let fileManager = FileManager.default
        var relative = path
        if let colon = relative.firstIndex(of: ":") {
            relative = String(relative[relative.index(after: colon)...])
        }
        while relative.hasPrefix("/") { relative.removeFirst() }
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        guard !relative.isEmpty else { return nil }

        let directCandidates = [
            baseDirectory.appendingPathComponent(relative),
            baseDirectory.appendingPathComponent((relative as NSString).lastPathComponent),
            baseDirectory.deletingLastPathComponent().appendingPathComponent(relative)
        ]
        for candidate in directCandidates {
            if fileManager.fileExists(atPath: candidate.path) {
                let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory != true { return candidate }
            }
        }

        let index = directoryIndex(for: baseDirectory)
        let variants = pathVariants(relative)
        for variant in variants {
            if let exact = index[variant] { return exact }
        }

        // Match by suffix only when the result is unambiguous.
        for variant in variants {
            let suffixMatches = index.compactMap { key, url -> (Int, URL)? in
                guard key.hasSuffix("/" + variant) || key.hasSuffix(variant) else { return nil }
                return (key.count, url)
            }.sorted { $0.0 < $1.0 }
            if suffixMatches.count == 1 { return suffixMatches[0].1 }
        }

        // Some exporters reference texture.png while the archive contains
        // texture.jpg / texture.dds. Match the filename stem across common
        // image extensions as a final rescue.
        let stem = (relative as NSString).deletingPathExtension
        for variant in pathVariants(stem) {
            let stemMatches = index.compactMap { key, url -> (Int, URL)? in
                let keyStem = (key as NSString).deletingPathExtension
                guard keyStem == variant || keyStem.hasSuffix("/" + variant) else { return nil }
                return (key.count, url)
            }.sorted { $0.0 < $1.0 }
            if stemMatches.count == 1 { return stemMatches[0].1 }
        }

        let lastComponent = (relative as NSString).lastPathComponent.lowercased()
        let basenameMatches: [(key: String, value: URL)] = index.filter {
            $0.key == lastComponent || $0.key.hasSuffix("/" + lastComponent)
        }
        if basenameMatches.count == 1 { return basenameMatches[0].value }

        // Do not guess by a "close enough" name. A wrong texture is worse
        // than a visible missing-texture warning, and guessing was the cause
        // of sibling models sharing each other's images.
        return nil
    }

    private static func searchStem(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return stem.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .precomposedStringWithCanonicalMapping
    }

    private func pathVariants(_ path: String) -> [String] {
        let lower = path.lowercased()
        let precomposed = lower.precomposedStringWithCanonicalMapping
        let decomposed = lower.decomposedStringWithCanonicalMapping
        return Array(Set([lower, precomposed, decomposed]))
    }

    private func directoryIndex(for baseDirectory: URL) -> [String: URL] {
        let key = baseDirectory.standardizedFileURL.path
        if let cached = directoryIndexCache[key] { return cached }
        var aliasMap = [String: Set<URL>]()
        if let enumerator = FileManager.default.enumerator(at: baseDirectory,
                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) {
            let prefix = baseDirectory.standardizedFileURL.path + "/"
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let path = url.standardizedFileURL.path
                let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
                for alias in MMDZipArchive.filenameAliases(relative) {
                    aliasMap[alias.lowercased(), default: []].insert(url)
                }
            }
        }
        // Only keep aliases that point at exactly one file. Code-page repairs
        // can map two different files onto one spelling; guessing between them
        // is the cross-model texture mix-up we must avoid.
        var index = [String: URL]()
        for (alias, urls) in aliasMap where urls.count == 1 {
            if let url = urls.first { index[alias] = url }
        }
        directoryIndexCache[key] = index
        return index
    }


    // MARK: - Texture creation

    private func makeTexture(_ data: [UInt8], width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        guard data.count >= width * height * 4 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: true
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        data.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: width * 4)
        }
        generateMipmaps(for: texture)
        return texture
    }

    private func generateMipmaps(for texture: MTLTexture) {
        guard texture.mipmapLevelCount > 1, let commandQueue else { return }
        guard let buffer = commandQueue.makeCommandBuffer(),
              let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    static func makeSolidTexture(device: MTLDevice, color: (UInt8, UInt8, UInt8, UInt8)) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let bytes: [UInt8] = [color.0, color.1, color.2, color.3]
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: 4)
        }
        return texture
    }

    static func makeToonRamps(device: MTLDevice) -> [MTLTexture] {
        // Ten small procedural ramps approximating MMD's built-in toon textures.
        let exponents: [Float] = [1.0, 1.6, 2.2, 3.0, 4.2, 0.7, 2.6, 3.6, 5.0, 1.2]
        let width = 256
        var textures = [MTLTexture]()
        for (index, exponent) in exponents.enumerated() {
            var pixels = [UInt8](repeating: 255, count: width * 4)
            for x in 0..<width {
                let t = Float(x) / Float(width - 1)
                var shade = powf(t, exponent)
                if index == 0 { shade = 1 }
                if index == 5 { shade = t > 0.5 ? 1 : 0.55 } // hard two-tone ramp
                let value = UInt8(max(0, min(255, shade * 255)))
                pixels[x * 4 + 0] = value
                pixels[x * 4 + 1] = value
                pixels[x * 4 + 2] = value
                pixels[x * 4 + 3] = 255
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: 1, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            if let texture = device.makeTexture(descriptor: descriptor) {
                pixels.withUnsafeBytes { raw in
                    texture.replace(region: MTLRegionMake2D(0, 0, width, 1),
                                    mipmapLevel: 0,
                                    withBytes: raw.baseAddress!,
                                    bytesPerRow: width * 4)
                }
                textures.append(texture)
            }
        }
        return textures
    }

    // MARK: - Image decoding

    struct DecodedImage {
        var data: [UInt8]
        var width: Int
        var height: Int
    }

    static func decodeImageFile(url: URL) -> DecodedImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "dds" || data.starts(with: [0x44, 0x44, 0x53, 0x20]) {
            if let decoded = MMDDDSDecoder.decode(data) { return decoded }
        }
        if ext == "tga" {
            if let decoded = decodeTGA(data) { return decoded }
        }
        if ext == "bmp" {
            if let decoded = decodeBMP(data) { return decoded }
        }
        if let decoded = decodeWithImageIO(data) { return decoded }
        if let decoded = decodeTGA(data) { return decoded }
        if let decoded = decodeBMP(data) { return decoded }
        if let decoded = MMDDDSDecoder.decode(data) { return decoded }
        return nil
    }

    static func decodeWithImageIO(_ data: Data) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return decodeCGImage(image)
    }

    static func decodeCGImage(_ image: CGImage) -> DecodedImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width * height < 200_000_000 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let success = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard success else { return nil }

        // CGContext produced premultiplied alpha; undo it for correct blending in Metal.
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[index + 3]
            if alpha > 0 && alpha < 255 {
                let scale = 255.0 / Float(alpha)
                pixels[index + 0] = UInt8(min(255, Float(pixels[index + 0]) * scale))
                pixels[index + 1] = UInt8(min(255, Float(pixels[index + 1]) * scale))
                pixels[index + 2] = UInt8(min(255, Float(pixels[index + 2]) * scale))
            }
        }
        return DecodedImage(data: pixels, width: width, height: height)
    }

    // MARK: - TGA

    static func decodeTGA(_ data: Data) -> DecodedImage? {
        guard data.count > 18 else { return nil }
        let bytes = [UInt8](data)
        let idLength = Int(bytes[0])
        let colorMapType = bytes[1]
        let imageType = bytes[2]
        guard colorMapType == 0 else { return nil }

        let width = Int(bytes[12]) | (Int(bytes[13]) << 8)
        let height = Int(bytes[14]) | (Int(bytes[15]) << 8)
        let depth = Int(bytes[16])
        let descriptor = bytes[17]
        guard width > 0, height > 0 else { return nil }

        var offset = 18 + idLength
        guard offset < bytes.count else { return nil }
        guard let (channels, isGrayscale) = tgaChannels(imageType: imageType, depth: depth) else { return nil }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let topOrigin = (descriptor & 0x20) != 0
        let rightOrigin = (descriptor & 0x10) != 0

        func store(x: Int, y: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) {
            let destX = rightOrigin ? (width - 1 - x) : x
            let destY = topOrigin ? y : (height - 1 - y)
            let index = (destY * width + destX) * 4
            pixels[index + 0] = rgba.0
            pixels[index + 1] = rgba.1
            pixels[index + 2] = rgba.2
            pixels[index + 3] = rgba.3
        }

        func readPixel() -> (UInt8, UInt8, UInt8, UInt8)? {
            guard offset + channels <= bytes.count else { return nil }
            if isGrayscale {
                let v = bytes[offset]
                offset += 1
                return (v, v, v, 255)
            }
            let b = bytes[offset], g = bytes[offset + 1], r = bytes[offset + 2]
            let a: UInt8 = channels == 4 ? bytes[offset + 3] : 255
            offset += channels
            return (r, g, b, a)
        }

        if imageType == 2 || imageType == 3 {
            let total = width * height
            for i in 0..<total {
                guard let p = readPixel() else { return nil }
                store(x: i % width, y: i / width, rgba: p)
            }
        } else if imageType == 10 || imageType == 11 {
            var i = 0
            while i < width * height {
                guard offset < bytes.count else { return nil }
                let header = bytes[offset]
                offset += 1
                let count = Int(header & 0x7F) + 1
                if header & 0x80 != 0 {
                    guard let p = readPixel() else { return nil }
                    for _ in 0..<count {
                        if i >= width * height { break }
                        store(x: i % width, y: i / width, rgba: p)
                        i += 1
                    }
                } else {
                    for _ in 0..<count {
                        guard let p = readPixel(), i < width * height else { return nil }
                        store(x: i % width, y: i / width, rgba: p)
                        i += 1
                    }
                }
            }
        } else {
            return nil
        }
        return DecodedImage(data: pixels, width: width, height: height)
    }

    private static func tgaChannels(imageType: UInt8, depth: Int) -> (Int, Bool)? {
        switch (imageType, depth) {
        case (3, 8), (11, 8): return (1, true)
        case (2, 24), (10, 24): return (3, false)
        case (2, 32), (10, 32): return (4, false)
        default: return nil
        }
    }

    // MARK: - BMP

    static func decodeBMP(_ data: Data) -> DecodedImage? {
        guard data.count > 54 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x42, bytes[1] == 0x4D else { return nil }

        let pixelOffset = Int(bytes[10]) | (Int(bytes[11]) << 8) | (Int(bytes[12]) << 16) | (Int(bytes[13]) << 24)
        let headerSize = Int(bytes[14]) | (Int(bytes[15]) << 8) | (Int(bytes[16]) << 16) | (Int(bytes[17]) << 24)
        guard headerSize >= 40, bytes.count >= 14 + headerSize else { return nil }

        let width = Int(Int32(bitPattern: UInt32(bytes[18]) | (UInt32(bytes[19]) << 8) | (UInt32(bytes[20]) << 16) | (UInt32(bytes[21]) << 24)))
        let rawHeight = Int32(bitPattern: UInt32(bytes[22]) | (UInt32(bytes[23]) << 8) | (UInt32(bytes[24]) << 16) | (UInt32(bytes[25]) << 24))
        let height = abs(Int(rawHeight))
        let topDown = rawHeight < 0
        let bpp = Int(bytes[28]) | (Int(bytes[29]) << 8)
        let compression = Int(bytes[30]) | (Int(bytes[31]) << 8)
        guard width > 0, height > 0, compression == 0, bpp == 24 || bpp == 32 else { return nil }

        let bytesPerPixel = bpp / 8
        let stride = ((width * bpp + 31) / 32) * 4
        guard pixelOffset >= 0, pixelOffset + stride * height <= bytes.count else { return nil }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let sourceY = topDown ? y : (height - 1 - y)
            let rowStart = pixelOffset + sourceY * stride
            for x in 0..<width {
                let src = rowStart + x * bytesPerPixel
                let dest = (y * width + x) * 4
                pixels[dest + 0] = bytes[src + 2]
                pixels[dest + 1] = bytes[src + 1]
                pixels[dest + 2] = bytes[src + 0]
                pixels[dest + 3] = bpp == 32 ? bytes[src + 3] : 255
            }
        }
        return DecodedImage(data: pixels, width: width, height: height)
    }
}

// MARK: - Original texture export

struct MMDTextureExportItem: Identifiable {
    let id: Int
    let path: String
    let sourceURL: URL?
    let byteCount: Int?

    var fileName: String {
        let raw = sourceURL?.lastPathComponent ?? (path as NSString).lastPathComponent
        let clean = raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let fallback = clean.isEmpty ? "texture_\(String(format: "%03d", id)).bin" : clean
        return String(format: "%03d_%@", id, fallback)
    }

    var isMissing: Bool { sourceURL == nil }
}

struct MMDTextureExportSummary {
    let directory: URL
    let exported: Int
    let missing: Int
    let manifestURL: URL
}

enum MMDTextureExporter {

    private static let fileManager = FileManager.default

    static func items(model: PMXModel, baseDirectory: URL?, fallbackRoot: URL?) -> [MMDTextureExportItem] {
        model.textures.enumerated().map { index, path in
            let url = resolve(path: path, baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
            var byteCount: Int?
            if let url,
               let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let number = attributes[.size] as? NSNumber {
                byteCount = number.intValue
            }
            return MMDTextureExportItem(id: index, path: path, sourceURL: url,
                                        byteCount: byteCount)
        }
    }

    /// Copies the original files without transcoding or recompression. The
    /// export folder is visible in Files because UIFileSharingEnabled is on.
    static func export(model: PMXModel,
                       baseDirectory: URL?,
                       fallbackRoot: URL?,
                       items: [MMDTextureExportItem]) throws -> MMDTextureExportSummary {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeName = model.displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = "\(safeName.isEmpty ? "Model" : safeName)-Textures-\(stampFormatter.string(from: Date()))"
        let directory = documents
            .appendingPathComponent("MMDStudio/Exports/Textures", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var exported = 0
        var missing = 0
        var manifest = "MMD Studio 贴图导出\n"
        manifest += "模型: \(model.displayName)\n"
        manifest += "时间: \(Date())\n"
        manifest += "说明: 以下文件按原始格式复制，未转码、未压缩。\n\n"

        for item in items {
            guard let sourceURL = item.sourceURL,
                  fileManager.fileExists(atPath: sourceURL.path) else {
                missing += 1
                manifest += "\(String(format: "%03d", item.id))\t缺失\t\(item.path)\n"
                continue
            }
            let destination = directory.appendingPathComponent(item.fileName)
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: sourceURL, to: destination)
                exported += 1
                let sizeText = item.byteCount.map { "\($0) bytes" } ?? "—"
                manifest += "\(String(format: "%03d", item.id))\tOK\t\(item.path)\t\(item.fileName)\t\(sizeText)\n"
            } catch {
                missing += 1
                manifest += "\(String(format: "%03d", item.id))\t复制失败\t\(item.path)\t\(error.localizedDescription)\n"
                MMDLog.shared.error("Texture export failed: \(item.path), \(error.localizedDescription)",
                                    category: "Texture")
            }
        }

        let manifestURL = directory.appendingPathComponent("_manifest.txt")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        MMDLog.shared.info("Textures exported: \(exported), missing=\(missing), folder=\(directory.path)",
                           category: "Texture")
        return MMDTextureExportSummary(directory: directory, exported: exported,
                                       missing: missing, manifestURL: manifestURL)
    }

    // A deliberately tolerant resolver for export. Decoding already has its
    // own cache-backed resolver; export must still list files that the GPU
    // decoder does not support (for example a DDS variant).
    private static func resolve(path: String,
                                baseDirectory: URL?,
                                fallbackRoot: URL?) -> URL? {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "//", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if normalized.contains("%"), let decoded = normalized.removingPercentEncoding {
            normalized = decoded
        }
        guard !normalized.isEmpty else { return nil }
        while normalized.hasPrefix("./") { normalized.removeFirst(2) }
        while normalized.hasPrefix("/") { normalized.removeFirst() }
        if let colon = normalized.firstIndex(of: ":") {
            normalized = String(normalized[normalized.index(after: colon)...])
        }

        let roots = [baseDirectory, fallbackRoot].compactMap { $0 }
        for root in roots {
            let candidates = [
                root.appendingPathComponent(normalized),
                root.appendingPathComponent((normalized as NSString).lastPathComponent),
                root.deletingLastPathComponent().appendingPathComponent(normalized)
            ]
            for candidate in candidates {
                if fileManager.fileExists(atPath: candidate.path) {
                    let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey])
                    if values?.isDirectory != true { return candidate }
                }
            }
        }

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let prefix = root.standardizedFileURL.path + "/"
            while let candidate = enumerator.nextObject() as? URL {
                if enumerator.level > 5 { enumerator.skipDescendants(); continue }
                let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true { continue }
                let path = candidate.standardizedFileURL.path
                let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : candidate.lastPathComponent
                let relativeAliases = Set(MMDZipArchive.filenameAliases(relative).map { $0.lowercased() })
                if relativeAliases.contains(normalized.lowercased()) { return candidate }
            }
        }
        return nil
    }
}
