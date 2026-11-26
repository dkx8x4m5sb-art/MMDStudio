import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// A small, dependency-free ZIP reader used by the model importer.
///
/// It supports the two compression methods that are produced by the Files app,
/// Finder, `zip`, and most MMD model archives: stored (0) and deflate (8).
/// ZIP64 central-directory records are accepted as well. Paths are sanitized
/// before extraction so an archive can never escape the destination folder.
enum MMDZipArchive {

    enum ZipError: LocalizedError {
        case invalidArchive(String)
        case unsupported(String)
        case truncated
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive(let message): return "ZIP 文件无效：\(message)"
            case .unsupported(let message): return "ZIP 不支持：\(message)"
            case .truncated: return "ZIP 数据不完整"
            case .checksumMismatch(let name): return "ZIP 校验失败：\(name)"
            }
        }
    }

    private struct Entry {
        var name: String
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var isDirectory: Bool
        /// Set only by the local-header recovery pass, where the payload end
        /// has to be guessed from the next signature instead of a size field.
        var dataEnd: Int? = nil
        /// Streaming archives write the CRC into a trailing descriptor, so the
        /// local header may still hold 0 and the check must be skipped.
        var skipCRC = false
    }

    /// Returns the names that could not be decoded, so the caller can log them
    /// instead of failing an otherwise usable import.
    @discardableResult
    static func extract(url: URL, to destination: URL) throws -> [String] {
        let declared = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ZipError.invalidArchive("无法读取文件（\(declared) 字节）：\(error.localizedDescription)。" +
                                          "如果文件在 iCloud 里，请先点开下载完成再导入")
        }
        // iCloud keeps a placeholder until the file is downloaded; reading it
        // then yields a short buffer and looks exactly like a corrupt ZIP.
        // Only a short read is evidence — a mapped file may legitimately
        // report a smaller count than the on-disk allocation.
        if declared > 0, data.count < declared {
            throw ZipError.invalidArchive("只读到 \(data.count)/\(declared) 字节，文件可能还在 iCloud 下载中，请等下载完成再试")
        }
        return try extract(data: data, to: destination)
    }

    @discardableResult
    static func extract(data: Data, to destination: URL) throws -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else {
            let hint = formatHint(bytes).map { "；\($0)" } ?? ""
            throw ZipError.invalidArchive("文件只有 \(bytes.count) 字节，不是完整的压缩包\(hint)")
        }
        let entries: [Entry]
        do {
            entries = try readCentralDirectory(bytes)
        } catch {
            // No readable end-of-central-directory: either the file is not a
            // ZIP at all, or it is a streaming archive whose trailer was lost.
            // Walking the local headers recovers everything the payload still
            // holds, which is the difference between "导入失败" and a usable
            // model for a truncated download.
            if let recovered = try? scanLocalHeaders(bytes), !recovered.isEmpty {
                entries = recovered
            } else if let hint = formatHint(bytes) {
                throw ZipError.invalidArchive(hint)
            } else {
                throw error
            }
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var skipped = [String]()
        var lastFailure: Error?
        for entry in entries {
            guard let relativePath = try? safePath(entry.name), !relativePath.isEmpty else {
                skipped.append(entry.name)
                continue
            }
            let outputURL = destination.appendingPathComponent(relativePath)
            if entry.isDirectory {
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let payload: Data
            do {
                payload = try extractPayload(entry: entry, bytes: bytes)
                if !entry.skipCRC, entry.uncompressedSize > 0, crc32(payload) != entry.crc {
                    throw ZipError.checksumMismatch(relativePath)
                }
            } catch {
                // A single bad record must not cost the whole archive: the PMX
                // and its textures are usually intact while one trailing
                // thumbnail is not. A fully broken archive still fails below.
                skipped.append(entry.name)
                lastFailure = error
                continue
            }
            try payload.write(to: outputURL, options: [.atomic])
        }
        if skipped.count == entries.count, let lastFailure {
            throw lastFailure
        }
        return skipped
    }

    // MARK: - Local header recovery

    /// Rebuild the entry list from the `PK\x03\x04` records alone. Streaming
    /// writers (some phone archivers and "保存到文件" flows) only emit local
    /// headers plus a data descriptor, and a download cut short loses the
    /// central directory entirely — both produce the same "找不到中央目录结尾"
    /// failure on a perfectly readable model.
    private static func scanLocalHeaders(_ bytes: [UInt8]) throws -> [Entry] {
        var entries = [Entry]()
        var cursor = 0
        while cursor + 30 <= bytes.count {
            guard readUInt32(bytes, cursor) == 0x0403_4B50 else {
                cursor += 1
                continue
            }
            let flags = readUInt16(bytes, cursor + 6)
            let method = readUInt16(bytes, cursor + 8)
            let crc = readUInt32(bytes, cursor + 14)
            let compressed = UInt64(readUInt32(bytes, cursor + 18))
            let uncompressed = UInt64(readUInt32(bytes, cursor + 22))
            let nameLength = Int(readUInt16(bytes, cursor + 26))
            let extraLength = Int(readUInt16(bytes, cursor + 28))
            let nameStart = cursor + 30
            let dataStart = nameStart + nameLength + extraLength
            guard nameLength > 0, nameLength < 4096, dataStart <= bytes.count else {
                cursor += 1
                continue
            }
            let nameBytes = Array(bytes[nameStart..<(nameStart + nameLength)])
            let name = decodeName(nameBytes, flags: flags)
            // A real entry name is readable text. Random payload bytes that
            // happen to spell PK\x03\x04 almost never are, so this filter is
            // what keeps a false signature from derailing the scan.
            guard !name.isEmpty,
                  !name.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0) || $0.value == 0xFFFD
                  }) else {
                cursor += 1
                continue
            }
            let hasDescriptor = (flags & 0x0008) != 0
            var dataEnd: Int?
            if compressed > 0, compressed < UInt64(bytes.count) {
                dataEnd = dataStart + Int(compressed)
            } else if method == 8, hasDescriptor {
                // Size lives in the trailing descriptor we cannot trust after a
                // truncation. Raw deflate stops at its final block, so a probe
                // decode tells us exactly how many bytes this entry owns.
                let probe = DeflateInflater(input: Array(bytes[dataStart...]), expectedSize: 0)
                if (try? probe.inflate()) != nil, probe.consumedBytes > 0 {
                    dataEnd = dataStart + probe.consumedBytes
                } else {
                    dataEnd = bytes.count
                }
            }
            if let end = dataEnd, end > bytes.count { dataEnd = nil }

            entries.append(Entry(name: name,
                                 flags: flags,
                                 method: method,
                                 crc: crc,
                                 compressedSize: compressed,
                                 uncompressedSize: uncompressed,
                                 localHeaderOffset: UInt64(cursor),
                                 isDirectory: name.hasSuffix("/") || name.hasSuffix("\\"),
                                 dataEnd: dataEnd,
                                 skipCRC: crc == 0))
            // Skip the payload (and its optional descriptor) before looking
            // for the next signature; without this, compressed data that
            // contains 0x04034b50 would be parsed as a bogus entry.
            var next = dataEnd ?? dataStart
            if hasDescriptor, next + 4 <= bytes.count, readUInt32(bytes, next) == 0x0807_4B50 {
                next += 16
            }
            cursor = max(next, cursor + 30)
        }
        guard !entries.isEmpty else { throw ZipError.invalidArchive("找不到中央目录结尾") }
        return entries
    }

    /// Explain what the file actually is. `.zip` is only a suffix; RAR and 7z
    /// archives are routinely renamed and cannot be opened on iOS without a
    /// third-party library, so saying so beats a generic corruption message.
    private static func formatHint(_ bytes: [UInt8]) -> String? {
        func matches(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            guard bytes.count >= offset + signature.count else { return false }
            for (index, byte) in signature.enumerated() where bytes[offset + index] != byte {
                return false
            }
            return true
        }
        if matches([0x52, 0x61, 0x72, 0x21]) {
            return "这其实是 RAR 压缩包（只是后缀写成了 .zip）。iOS 不能直接解压 RAR，请先在「文件」里解压，再把解压出的文件夹拖进来导入"
        }
        if matches([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            return "这其实是 7z 压缩包（只是后缀写成了 .zip）。请先解压成文件夹再导入"
        }
        if matches([0x1F, 0x8B]) {
            return "这其实是 gzip 文件，不是 ZIP。请先解压成文件夹再导入"
        }
        if matches([0x42, 0x5A, 0x68]) {
            return "这其实是 bzip2 文件，不是 ZIP。请先解压成文件夹再导入"
        }
        if matches([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return "这其实是 xz 文件，不是 ZIP。请先解压成文件夹再导入"
        }
        if matches([0x50, 0x4B]) {
            return "压缩包里有 ZIP 记录但中央目录已损坏（多半是下载不完整）。请重新下载，或先解压成文件夹再导入"
        }
        return nil
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        var endOffset = -1
        let lowerBound = max(0, bytes.count - 22 - 65_535)
        var cursor = bytes.count - 22
        while cursor >= lowerBound {
            if readUInt32(bytes, cursor) == 0x0605_4B50 {
                endOffset = cursor
                break
            }
            cursor -= 1
        }
        guard endOffset >= 0 else { throw ZipError.invalidArchive("找不到中央目录结尾") }

        var totalEntries = UInt64(readUInt16(bytes, endOffset + 10))
        var centralSize = UInt64(readUInt32(bytes, endOffset + 12))
        var centralOffset = UInt64(readUInt32(bytes, endOffset + 16))

        // ZIP64 locator sits immediately before the classic EOCD record.
        if endOffset >= 20, readUInt32(bytes, endOffset - 20) == 0x0706_4B50 {
            let zip64Offset = readUInt64(bytes, endOffset - 20 + 8)
            guard zip64Offset < UInt64(bytes.count),
                  readUInt32(bytes, Int(zip64Offset)) == 0x0606_4B50 else {
                throw ZipError.invalidArchive("ZIP64 结尾无效")
            }
            totalEntries = readUInt64(bytes, Int(zip64Offset) + 32)
            centralSize = readUInt64(bytes, Int(zip64Offset) + 40)
            centralOffset = readUInt64(bytes, Int(zip64Offset) + 48)
        }

        guard centralOffset < UInt64(bytes.count),
              centralSize <= UInt64(bytes.count),
              centralOffset + centralSize <= UInt64(bytes.count) else {
            throw ZipError.truncated
        }

        var entries = [Entry]()
        entries.reserveCapacity(Int(min(totalEntries, 100_000)))
        var offset = Int(centralOffset)
        let centralEnd = Int(centralOffset + centralSize)

        for _ in 0..<Int(min(totalEntries, 1_000_000)) {
            guard offset + 46 <= centralEnd,
                  readUInt32(bytes, offset) == 0x0201_4B50 else {
                throw ZipError.invalidArchive("中央目录条目损坏")
            }
            let flags = readUInt16(bytes, offset + 8)
            let method = readUInt16(bytes, offset + 10)
            let crc = readUInt32(bytes, offset + 16)
            var compressedSize = UInt64(readUInt32(bytes, offset + 20))
            var uncompressedSize = UInt64(readUInt32(bytes, offset + 24))
            let nameLength = Int(readUInt16(bytes, offset + 28))
            let extraLength = Int(readUInt16(bytes, offset + 30))
            let commentLength = Int(readUInt16(bytes, offset + 32))
            let diskStart = readUInt16(bytes, offset + 34)
            let externalAttributes = readUInt32(bytes, offset + 38)
            var localHeaderOffset = UInt64(readUInt32(bytes, offset + 42))

            let nameStart = offset + 46
            let extraStart = nameStart + nameLength
            let recordEnd = extraStart + extraLength + commentLength
            guard recordEnd <= centralEnd else { throw ZipError.truncated }

            let nameBytes = Array(bytes[nameStart..<(nameStart + nameLength)])
            let name = decodeName(nameBytes, flags: flags)
            let isDirectory = name.hasSuffix("/") || name.hasSuffix("\\")
                || (externalAttributes & 0x10) != 0

            // Parse the Zip64 extra field when any 32-bit value was saturated.
            if uncompressedSize == 0xFFFF_FFFF || compressedSize == 0xFFFF_FFFF
                || localHeaderOffset == 0xFFFF_FFFF || diskStart == 0xFFFF {
                var extraCursor = extraStart
                let extraEnd = extraStart + extraLength
                while extraCursor + 4 <= extraEnd {
                    let identifier = readUInt16(bytes, extraCursor)
                    let size = Int(readUInt16(bytes, extraCursor + 2))
                    let dataStart = extraCursor + 4
                    guard dataStart + size <= extraEnd else { break }
                    if identifier == 0x0001 {
                        var valueCursor = dataStart
                        if uncompressedSize == 0xFFFF_FFFF, valueCursor + 8 <= dataStart + size {
                            uncompressedSize = readUInt64(bytes, valueCursor)
                            valueCursor += 8
                        }
                        if compressedSize == 0xFFFF_FFFF, valueCursor + 8 <= dataStart + size {
                            compressedSize = readUInt64(bytes, valueCursor)
                            valueCursor += 8
                        }
                        if localHeaderOffset == 0xFFFF_FFFF, valueCursor + 8 <= dataStart + size {
                            localHeaderOffset = readUInt64(bytes, valueCursor)
                            valueCursor += 8
                        }
                    }
                    extraCursor = dataStart + size
                }
            }

            entries.append(Entry(name: name,
                                 flags: flags,
                                 method: method,
                                 crc: crc,
                                 compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize,
                                 localHeaderOffset: localHeaderOffset,
                                 isDirectory: isDirectory))
            offset = recordEnd
        }
        return entries
    }

    // MARK: - Payload

    private static func extractPayload(entry: Entry, bytes: [UInt8]) throws -> Data {
        guard entry.flags & 0x0001 == 0, entry.flags & 0x0040 == 0 else {
            throw ZipError.unsupported("加密 ZIP 需要密码")
        }
        guard entry.uncompressedSize <= 1_073_741_824 else {
            throw ZipError.unsupported("单个文件超过 1 GB")
        }
        let header = Int(entry.localHeaderOffset)
        guard header + 30 <= bytes.count,
              readUInt32(bytes, header) == 0x0403_4B50 else {
            throw ZipError.invalidArchive("本地文件头损坏：\(entry.name)")
        }
        let nameLength = Int(readUInt16(bytes, header + 26))
        let extraLength = Int(readUInt16(bytes, header + 28))
        let dataOffset = header + 30 + nameLength + extraLength
        guard dataOffset <= bytes.count else { throw ZipError.truncated }
        let compressedEnd = entry.dataEnd.map { min($0, bytes.count) }
            ?? (dataOffset + Int(entry.compressedSize))
        guard compressedEnd >= dataOffset, compressedEnd <= bytes.count else { throw ZipError.truncated }
        let compressed = Array(bytes[dataOffset..<compressedEnd])

        switch entry.method {
        case 0:
            let expected = entry.uncompressedSize > 0 ? entry.uncompressedSize : UInt64(compressed.count)
            guard UInt64(compressed.count) == expected else {
                throw ZipError.invalidArchive("存储文件长度不一致：\(entry.name)")
            }
            return Data(compressed)
        case 8:
            let inflater = DeflateInflater(input: compressed,
                                           expectedSize: Int(entry.uncompressedSize))
            return Data(try inflater.inflate())
        default:
            throw ZipError.unsupported("压缩方式 \(entry.method)：\(entry.name)")
        }
    }

    /// Windows CP932 / GBK / Big5 are common in MMD archives created on
    /// Japanese or Chinese Windows. Foundation's generic .shiftJIS does not
    /// cover every CP932 extension, so use the DOS encodings explicitly.
    private static let cp932Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0420)))
    private static let gbkEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0421)))
    private static let big5Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0423)))

    private static func decodeName(_ bytes: [UInt8], flags: UInt16) -> String {
        let data = Data(bytes)
        if flags & 0x0800 != 0, let text = String(data: data, encoding: .utf8) {
            return text
        }

        // Do not return the first decodable string blindly: CP1252 and Latin-1
        // decode almost every byte sequence, which turns Chinese/Japanese
        // names into mojibake such as "ÎaäÆ÷2". Score candidates instead.
        let candidates: [(String.Encoding, String)] = [
            (.utf8, "utf8"),
            (cp932Encoding, "cp932"),
            (gbkEncoding, "gbk"),
            (big5Encoding, "big5"),
            (.shiftJIS, "shiftjis"),
            (.isoLatin1, "latin1"),
        ]
        var best: (text: String, score: Int, order: Int)?
        for (order, item) in candidates.enumerated() {
            guard let text = String(data: data, encoding: item.0), !text.isEmpty else { continue }
            var score = qualityScore(text)
            if order == 0 { score += 8 } // A valid UTF-8 name is strongly preferred.
            if best == nil || score > best!.score {
                best = (text, score, order)
            }
        }
        if let best { return repairedFilename(best.text) ?? best.text }
        return String(describing: bytes)
    }

    private static func qualityScore(_ text: String) -> Int {
        var score = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xAC00...0xD7AF: score += 4
            case 0x3040...0x30FF: score += 3
            case 0x20...0x7E: score += 1
            case 0x0300...0x036F: score -= 8
            case 0x80...0x2FF: score -= 3
            default: score -= 1
            }
        }
        return score
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    /// Some archives have already been damaged by an earlier CP1252/Latin-1
    /// extraction. Reverse that mapping and try the CJK encodings again.
    static func repairedFilename(_ rawName: String) -> String? {
        let name = rawName.precomposedStringWithCanonicalMapping
        let candidates: [String.Encoding] = [.windowsCP1252, .isoLatin1]
        for sourceEncoding in candidates {
            guard let data = name.data(using: sourceEncoding), !data.isEmpty else { continue }
            for encoding in [cp932Encoding, gbkEncoding, big5Encoding, .utf8] {
                guard let candidate = String(data: data, encoding: encoding),
                      candidate != name, containsCJK(candidate) else { continue }
                if qualityScore(candidate) > qualityScore(name) { return candidate }
            }
        }
        return nil
    }

    static func filenameAliases(_ name: String) -> [String] {
        let precomposed = name.precomposedStringWithCanonicalMapping
        let decomposed = name.decomposedStringWithCanonicalMapping
        var values = [name, precomposed, decomposed]
        if let repaired = repairedFilename(name) {
            values.append(repaired)
            values.append(repaired.precomposedStringWithCanonicalMapping)
            values.append(repaired.decomposedStringWithCanonicalMapping)
        }
        // A damaged archive usually corrupts every path component, not the
        // whole path as one string. Repair the folder and file names
        // separately so "Texture/脸.png" still resolves after import.
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map { component -> String in
            let value = String(component)
            return repairedFilename(value) ?? value
        }
        let repairedPath = components.joined(separator: "/")
        values.append(repairedPath)
        values.append(repairedPath.precomposedStringWithCanonicalMapping)
        values.append(repairedPath.decomposedStringWithCanonicalMapping)
        // Shift-JIS archives opened by a GBK-oriented tool (or the reverse)
        // produce names like 懱.png where the PMX asks for 体.png. Re-encode
        // each component through the common CJK code pages so the real file
        // becomes reachable under the spelling the model actually uses.
        for variant in reencodedVariants(repairedPath) {
            values.append(variant)
            values.append(variant.precomposedStringWithCanonicalMapping)
            values.append(variant.decomposedStringWithCanonicalMapping)
        }
        for variant in reencodedVariants(precomposed) {
            values.append(variant)
            values.append(variant.precomposedStringWithCanonicalMapping)
            values.append(variant.decomposedStringWithCanonicalMapping)
        }
        return Array(Set(values))
    }

    /// Names produced when a path is encoded in one code page and decoded in
    /// another. Only used as lookup aliases; a caller must still confirm that
    /// the target file exists.
    static func reencodedVariants(_ rawName: String) -> [String] {
        let name = rawName.precomposedStringWithCanonicalMapping
        let encodings: [String.Encoding] = [cp932Encoding, gbkEncoding, big5Encoding, .utf8]
        var out = [String]()
        for source in encodings {
            guard let data = name.data(using: source), !data.isEmpty else { continue }
            for target in encodings where target != source {
                guard let candidate = String(data: data, encoding: target),
                      candidate != name else { continue }
                // Drop control characters and replacement glyphs; those
                // conversions are noise rather than recoverable filenames.
                guard !candidate.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0) || $0.value == 0xFFFD
                }) else { continue }
                out.append(candidate)
            }
        }
        return Array(Set(out))
    }

    private static func safePath(_ raw: String) throws -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        var components = [String]()
        for component in normalized.split(separator: "/", omittingEmptySubsequences: false) {
            let value = String(component)
            if value.isEmpty || value == "." { continue }
            if value == ".." { throw ZipError.invalidArchive("包含非法路径：\(raw)") }
            if value.contains(":") || value.hasPrefix("~") { continue }
            components.append(value)
        }
        return components.joined(separator: "/")
    }

    // MARK: - Byte helpers

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        return UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(readUInt32(bytes, offset)) | UInt64(readUInt32(bytes, offset + 4)) << 32
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { value -> UInt32 in
            var c = UInt32(value)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
            }
            return c
        }
    }()
}

// MARK: - Raw deflate

private final class DeflateInflater {

    private let input: [UInt8]
    private let expectedSize: Int
    private var bitPosition = 0
    private var output = [UInt8]()
    /// Bytes of the input that belonged to the deflate stream. A streaming
    /// entry has no size in its local header, so this is the only way to know
    /// where its payload ends and the next record begins.
    private(set) var consumedBytes = 0

    init(input: [UInt8], expectedSize: Int) {
        self.input = input
        self.expectedSize = max(0, expectedSize)
        output.reserveCapacity(self.expectedSize)
    }

    func inflate() throws -> [UInt8] {
        var isFinal = false
        while !isFinal {
            isFinal = try readBits(1) == 1
            let type = try readBits(2)
            switch type {
            case 0: try readStoredBlock()
            case 1: try readHuffmanBlock(fixed: true)
            case 2: try readHuffmanBlock(fixed: false)
            default: throw MMDZipArchive.ZipError.invalidArchive("无效的 deflate 块")
            }
            if expectedSize > 0, output.count > expectedSize {
                throw MMDZipArchive.ZipError.invalidArchive("解压数据超过标称长度")
            }
        }
        consumedBytes = (bitPosition + 7) / 8
        if expectedSize > 0, output.count != expectedSize {
            throw MMDZipArchive.ZipError.truncated
        }
        return output
    }

    private func readStoredBlock() throws {
        alignToByte()
        let length = try readBits(16)
        let complement = try readBits(16)
        guard (length ^ 0xFFFF) == complement else {
            throw MMDZipArchive.ZipError.invalidArchive("deflate 长度校验失败")
        }
        guard length >= 0 else { throw MMDZipArchive.ZipError.truncated }
        for _ in 0..<length {
            guard bitPosition / 8 < input.count else { throw MMDZipArchive.ZipError.truncated }
            append(input[bitPosition / 8])
            bitPosition += 8
        }
    }

    private func readHuffmanBlock(fixed: Bool) throws {
        let literalLengths: [Int]
        let distanceLengths: [Int]
        if fixed {
            literalLengths = DeflateInflater.fixedLiteralLengths
            distanceLengths = [Int](repeating: 5, count: 32)
        } else {
            let literalCount = try readBits(5) + 257
            let distanceCount = try readBits(5) + 1
            let codeLengthCount = try readBits(4) + 4
            let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            var codeLengths = [Int](repeating: 0, count: 19)
            for index in 0..<codeLengthCount {
                codeLengths[order[index]] = try readBits(3)
            }
            let codeTable = try HuffmanTable(lengths: codeLengths)
            var lengths = [Int]()
            lengths.reserveCapacity(literalCount + distanceCount)
            while lengths.count < literalCount + distanceCount {
                let symbol = try decode(codeTable)
                switch symbol {
                case 0...15:
                    lengths.append(symbol)
                case 16:
                    guard let last = lengths.last else { throw MMDZipArchive.ZipError.invalidArchive("重复码无前值") }
                    let count = try readBits(2) + 3
                    for _ in 0..<count { lengths.append(last) }
                case 17:
                    let count = try readBits(3) + 3
                    lengths.append(contentsOf: repeatElement(0, count: count))
                case 18:
                    let count = try readBits(7) + 11
                    lengths.append(contentsOf: repeatElement(0, count: count))
                default:
                    throw MMDZipArchive.ZipError.invalidArchive("无效的码长符号")
                }
            }
            guard lengths.count == literalCount + distanceCount else {
                throw MMDZipArchive.ZipError.invalidArchive("码长数量不一致")
            }
            literalLengths = Array(lengths[0..<literalCount])
            distanceLengths = Array(lengths[literalCount..<lengths.count])
        }

        let literalTable = try HuffmanTable(lengths: literalLengths)
        let distanceTable = try HuffmanTable(lengths: distanceLengths)
        let lengthBases = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27,
                           31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        let lengthExtras = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
                            2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        let distanceBases = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
                             193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
                             6145, 8193, 12289, 16385, 24577]
        let distanceExtras = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
                              6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

        while true {
            let symbol = try decode(literalTable)
            if symbol < 256 {
                append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }
            guard symbol >= 257 && symbol <= 285 else {
                throw MMDZipArchive.ZipError.invalidArchive("无效的长度符号 \(symbol)")
            }
            let lengthIndex = symbol - 257
            guard lengthIndex < lengthBases.count else {
                throw MMDZipArchive.ZipError.invalidArchive("长度符号越界")
            }
            let length = lengthBases[lengthIndex] + (try readBits(lengthExtras[lengthIndex]))
            let distanceSymbol = try decode(distanceTable)
            guard distanceSymbol >= 0 && distanceSymbol < distanceBases.count else {
                throw MMDZipArchive.ZipError.invalidArchive("无效的距离符号")
            }
            let distance = distanceBases[distanceSymbol] + (try readBits(distanceExtras[distanceSymbol]))
            guard distance > 0, distance <= output.count else {
                throw MMDZipArchive.ZipError.invalidArchive("距离超出输出窗口")
            }
            for _ in 0..<length {
                append(output[output.count - distance])
            }
        }
    }

    private func decode(_ table: HuffmanTable) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for length in 1...table.maxBits {
            code |= try readBits(1)
            let count = table.counts[length]
            if code >= first && code - first < count {
                return table.symbols[index + code - first]
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw MMDZipArchive.ZipError.invalidArchive("Huffman 解码失败")
    }

    private func append(_ byte: UInt8) {
        output.append(byte)
    }

    private func readBits(_ count: Int) throws -> Int {
        var value = 0
        for shift in 0..<count {
            guard bitPosition < input.count * 8 else { throw MMDZipArchive.ZipError.truncated }
            let byte = input[bitPosition / 8]
            let bit = (Int(byte) >> (bitPosition % 8)) & 1
            value |= bit << shift
            bitPosition += 1
        }
        return value
    }

    private func alignToByte() {
        bitPosition = (bitPosition + 7) & ~7
    }

    private static let fixedLiteralLengths: [Int] = {
        var lengths = [Int](repeating: 0, count: 288)
        for index in 0...143 { lengths[index] = 8 }
        for index in 144...255 { lengths[index] = 9 }
        for index in 256...279 { lengths[index] = 7 }
        for index in 280...287 { lengths[index] = 8 }
        return lengths
    }()
}

private struct HuffmanTable {
    let counts: [Int]
    let symbols: [Int]
    let maxBits: Int

    init(lengths: [Int]) throws {
        guard let maximum = lengths.max(), maximum > 0, maximum <= 15 else {
            throw MMDZipArchive.ZipError.invalidArchive("Huffman 表为空")
        }
        maxBits = maximum
        var counts = [Int](repeating: 0, count: maximum + 1)
        for length in lengths where length > 0 {
            counts[length] += 1
        }
        var offsets = [Int](repeating: 0, count: maximum + 1)
        for length in 1...maximum {
            offsets[length] = offsets[length - 1] + counts[length - 1]
        }
        var symbols = [Int](repeating: 0, count: lengths.count)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            symbols[offsets[length]] = symbol
            offsets[length] += 1
        }
        self.counts = counts
        self.symbols = symbols
    }
}
