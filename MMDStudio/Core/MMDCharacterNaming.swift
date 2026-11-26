import Foundation

/// Turns the names an MMD archive actually contains into a character folder
/// name plus an outfit/prop label.
///
/// The hard part is that archive titles are named after the *series*
/// (`3.0绳匠_by_绝区零_…` holds 玲 and 哲) while model headers are named after
/// the person or the outfit (`蕾米埃尔-白`). Everything here is pure string
/// work plus a file-size lookup, so it can be tested without UIKit.
enum MMDCharacterNaming {

    struct Input {
        var id: String
        var displayName: String
        var pmxPath: String
        var packagePath: String
        var relativePath: String
    }

    struct Output {
        /// Folder name: 蕾米埃尔, 玲, 哲.
        var characterName: String
        /// Row name inside that folder: 白, 泳装, 武器. Nil when the model is
        /// the character itself.
        var variantName: String?
        var isProp: Bool
    }

    // MARK: - Entry point

    static func classify(_ inputs: [Input]) -> [Output] {
        let known = Set(inputs.map { normalize(clean($0.displayName)) })
        let sizes = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, fileSize($0.pmxPath)) })
        var outputs = [Output](repeating: Output(characterName: "", variantName: nil, isProp: false),
                               count: inputs.count)

        var byPackage: [String: [Int]] = [:]
        for (index, item) in inputs.enumerated() {
            byPackage[item.packagePath, default: []].append(index)
        }

        for group in byPackage.values {
            guard let firstIndex = group.first else { continue }
            let packageLabel = clean(URL(fileURLWithPath: inputs[firstIndex].packagePath).lastPathComponent)
            var parsed = [Parsed]()
            for index in group {
                parsed.append(parse(inputs[index].displayName,
                                    packageLabel: packageLabel,
                                    known: known))
            }
            // A bare prop name (武器.pmx / 扇子.pmx) says nothing about who it
            // belongs to, so it follows the largest character in its archive.
            var owner: String?
            var ownerSize = -1
            for (offset, index) in group.enumerated() where !parsed[offset].character.isEmpty {
                let size = sizes[inputs[index].id] ?? 0
                if size > ownerSize {
                    ownerSize = size
                    owner = parsed[offset].character
                }
            }

            var used = Set<String>()
            for (offset, index) in group.enumerated() {
                var value = parsed[offset]
                if value.character.isEmpty {
                    value.character = owner ?? clean(inputs[index].displayName)
                }
                let fullName = clean(inputs[index].displayName)
                let character = shortCharacterName(value.character)
                var variant = value.variant
                if variant == nil, value.isProp {
                    let label = propLabel(displayName: inputs[index].displayName,
                                          pmxPath: inputs[index].pmxPath,
                                          character: character,
                                          folderName: URL(fileURLWithPath: inputs[index].packagePath).lastPathComponent,
                                          packageName: inputs[firstIndex].packagePath)
                    variant = label.isEmpty ? nil : label
                }
                // "菲欧尼皮肤" files under 菲欧尼 and the row says 皮肤, not a
                // second identical 菲欧尼 line.
                if variant == nil, character != fullName, fullName.hasPrefix(character) {
                    let suffixText = String(fullName.dropFirst(character.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "-—·. /\\").union(.whitespaces))
                    variant = suffixText.isEmpty ? nil : suffixText
                }
                // Two exports of the same outfit must not read as two
                // identical rows; the second falls back to the archive's own
                // wording and finally to a counter.
                var row = variant ?? character
                if used.contains(normalize(row)) {
                    let alternative = fullName.isEmpty || fullName == character ? "" : fullName
                    if !alternative.isEmpty { row = alternative }
                }
                let base = row
                var counter = 2
                while used.contains(normalize(row)) {
                    row = "\(base) \(counter)"
                    counter += 1
                }
                used.insert(normalize(row))

                outputs[index] = Output(characterName: character,
                                        variantName: row == character ? nil : row,
                                        isProp: value.isProp)
            }
        }
        return outputs
    }

    // MARK: - Name parsing

    private struct Parsed {
        var character: String
        var variant: String?
        var isProp: Bool
    }

    private static func parse(_ raw: String,
                              packageLabel: String,
                              known: Set<String>) -> Parsed {
        let name = clean(raw)
        let parts = split(name)
        guard parts.count >= 2 else {
            let bare = parts.first ?? name
            let prop = isPropWord(bare)
            return Parsed(character: prop ? "" : bare, variant: prop ? bare : nil, isProp: prop)
        }
        let last = parts[parts.count - 1]
        let head = parts.dropLast().joined(separator: "-")
        if isPropWord(last) {
            return Parsed(character: head, variant: last, isProp: true)
        }
        if isVariantWord(last) {
            return Parsed(character: head, variant: last, isProp: false)
        }
        // "铃 2" is a second copy of 铃, not a character called 2.
        if last.allSatisfy({ $0.isNumber }) {
            return Parsed(character: head, variant: "v\(last)", isProp: false)
        }
        // `玲` vs `绳匠 玲`: the tail is a name that exists on its own in the
        // library, so the head is the series.
        if known.contains(normalize(last)) {
            return Parsed(character: last, variant: nil, isProp: false)
        }
        // The head repeats the archive name — 3.0绳匠_玲 — and that is a
        // faction, not a person.
        if isFactionWord(head) || parts.dropLast().contains(where: isFactionWord) {
            return Parsed(character: last, variant: nil, isProp: false)
        }
        if !packageLabel.isEmpty,
           packageLabel.contains(head) || head.contains(packageLabel) {
            return Parsed(character: last, variant: nil, isProp: false)
        }
        return Parsed(character: name, variant: nil, isProp: false)
    }

    static func split(_ name: String) -> [String] {
        let separators = CharacterSet(charactersIn: "-—－–_·・.．/\\ 　\t")
        return name.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Strip the packaging noise authors add around a model name: version
    /// prefixes, `_by_作者`, download hashes and doubled separators.
    static func clean(_ raw: String) -> String {
        var value = raw.precomposedStringWithCanonicalMapping
        let hasCJK = value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if !hasCJK, let repaired = MMDZipArchive.repairedFilename(value), repaired != value {
            value = repaired
        }
        if let range = value.range(of: "_by_", options: [.caseInsensitive]) {
            value = String(value[..<range.lowerBound])
        }
        value = value.replacingOccurrences(of: #"[\s_-]*[0-9a-fA-F]{16,}$"#,
                                           with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"^[vV]?\d+(?:\.\d+){1,3}(?=[^0-9A-Za-z]|$)"#,
                                           with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "_", with: " ")
        value = value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalize(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        for character in lowered where !" -_—－·・.．/\\".contains(character) {
            out.append(character)
        }
        return out
    }

    private static func isPropWord(_ text: String) -> Bool {
        propWords.contains(normalize(text))
    }

    private static func isVariantWord(_ text: String) -> Bool {
        variantWords.contains(normalize(text))
    }

    private static func isFactionWord(_ text: String) -> Bool {
        factionWords.contains(normalize(text))
    }

    /// Weapons and hand props. A match folds the model under its character.
    private static let propWords: Set<String> = [
        "武器", "刀", "剑", "槍", "枪", "弓", "扇", "扇子", "伞", "傘", "盾", "杖", "锤", "鎚",
        "斧", "匕首", "双刀", "太刀", "长枪", "道具", "配饰", "配件", "背包", "帽子", "眼镜",
        "面具", "头饰", "饰品", "披风", "尾巴", "翅膀", "宠物", "法杖", "枪械", "弹药", "手持",
        "挂件", "发饰", "耳机", "吉他", "麦克风", "花束", "书", "箱", "球", "棒", "鞭", "镰",
        "拳套", "角", "weapon", "sword", "katana", "gun", "rifle", "prop", "accessory",
        "hat", "glasses", "mask", "bag", "backpack",
    ]

    /// Outfits and alternate forms of the *same* person.
    private static let variantWords: Set<String> = [
        "白", "黑", "泳装", "泳衣", "死库水", "常服", "私服", "制服", "校服", "战斗服", "礼服",
        "婚纱", "和服", "浴衣", "睡衣", "皮肤", "换色", "异色", "觉醒", "初始", "破损", "战损",
        "改造", "幼年", "成年", "限定", "活动", "新装", "夏装", "冬装", "春装", "秋装", "正装",
        "便服", "工作服", "女仆", "护士", "警服", "军装", "特别版", "默认", "普通",
        "白发", "黑发", "金发", "ver", "ver2", "v2", "alt", "default", "normal",
    ]

    /// Series and faction names that appear in archive titles. A match is
    /// dropped from the folder name so 绳匠 never becomes a character.
    private static let factionWords: Set<String> = [
        "绳匠", "絕區零", "绝区零", "崩坏", "崩壞", "星穹铁道", "星穹鐵道", "原神", "鸣潮",
        "明日方舟", "蔚蓝档案", "碧蓝航线", "少女前线", "胜利女神", "尘白禁区", "深空之眼",
        "战双帕弥什", "重返未来", "无限暖暖", "恋与深空", "幻塔", "崩坏3", "崩坏学园",
        "集合", "合集", "全角色", "パック", "まとめ",
    ]

    static func shortCharacterName(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespaces)
        for suffix in ["皮肤", "模型", "本体", "角色", "（正常版）", "(正常版)", "（模型）"]
        where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return value.isEmpty ? name : value
    }

    static func propLabel(displayName: String,
                          pmxPath: String,
                          character: String,
                          folderName: String,
                          packageName: String) -> String {
        var stem = URL(fileURLWithPath: pmxPath).deletingPathExtension().lastPathComponent
        if let repaired = MMDZipArchive.repairedFilename(stem), repaired != stem { stem = repaired }
        stem = clean(stem)
        for token in [displayName, character, folderName,
                      URL(fileURLWithPath: packageName).lastPathComponent] where token.count >= 2 {
            if stem.lowercased().hasPrefix(token.lowercased()) {
                stem = String(stem.dropFirst(token.count))
            }
        }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "-—·. /\\").union(.whitespaces))
        if stem.isEmpty || stem == character { stem = "配饰" }
        return String(stem.prefix(20))
    }

    /// The header often only repeats the character while the file name carries
    /// the outfit (`蕾米埃尔_白`); keep whichever says more.
    static func preferredDisplayName(header: String, fileName: String, packageName: String) -> String {
        var headerName = clean(header)
        var file = clean(fileName)
        let generic: Set<String> = ["model", "mesh", "body", "character", "mmd", "main",
                                    "untitled", "pmx", "pmd", "default", "モデル", "模型"]
        if generic.contains(headerName.lowercased()) { headerName = "" }
        if generic.contains(file.lowercased()) { file = "" }

        if !headerName.isEmpty, !file.isEmpty, file.count > headerName.count,
           file.lowercased().contains(headerName.lowercased()) {
            return file
        }
        if !headerName.isEmpty { return headerName }
        if !file.isEmpty { return file }
        let fallback = clean(packageName)
        return fallback.isEmpty ? packageName : fallback
    }

    private static func fileSize(_ path: String) -> Int {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
