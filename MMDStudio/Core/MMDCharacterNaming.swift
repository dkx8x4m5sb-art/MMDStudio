//
//  MMDCharacterNaming.swift
//  MMD Studio
//
//  从模型名与压缩包结构推断角色名、款式名与道具归属。
//

import Foundation

/// 把 MMD 压缩包里真实存在的名字，变成一个角色目录名
/// 加一个款式/道具标签。
///
/// 难处在于压缩包标题按*系列*命名
/// （`3.0绳匠_by_绝区零_…` 里装着玲和哲），而模型头部按
/// 人物或款式命名（`蕾米埃尔-白`）。这里全是纯字符串
/// 处理加一次文件大小查询，不依赖 UIKit，可以直接测。
enum MMDCharacterNaming {

    struct Input {
        var id: String
        var displayName: String
        var pmxPath: String
        var packagePath: String
        var relativePath: String
    }

    struct Output {
        /// 目录名：蕾米埃尔、玲、哲。
        var characterName: String
        /// 目录内的行名：白、泳装、武器。模型
        /// 就是角色本身时为空。
        var variantName: String?
        var isProp: Bool
    }

    // MARK: - 入口

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
            // 一个光杆道具名（武器.pmx / 扇子.pmx）说明不了它
            // 属于谁，所以它跟随包里最大的那个角色。
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
                // 「菲欧尼皮肤」归到 菲欧尼 下，行名写 皮肤，
                // 而不是又出现一行一模一样的 菲欧尼。
                if variant == nil, character != fullName, fullName.hasPrefix(character) {
                    let suffixText = String(fullName.dropFirst(character.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "-—·. /\\").union(.whitespaces))
                    variant = suffixText.isEmpty ? nil : suffixText
                }
                // 同一套衣服的两次导出不能显示成两行
                // 一模一样的名字；第二个退回到压缩包自己的
                // 措辞，最后再退到计数器。
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

    // MARK: - 名字解析

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
        // 「铃 2」是 铃 的第二份拷贝，不是有个角色叫 2。
        if last.allSatisfy({ $0.isNumber }) {
            return Parsed(character: head, variant: "v\(last)", isProp: false)
        }
        // 「玲」与「绳匠 玲」：尾巴是库里独立存在的名字，
        // 所以前半截是系列。
        if known.contains(normalize(last)) {
            return Parsed(character: last, variant: nil, isProp: false)
        }
        // 前半截重复了压缩包名 —— 3.0绳匠_玲 —— 那是
        // 阵营，不是人物。
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

    /// 去掉作者在模型名周围加的包装噪声：版本
    /// 前缀、`_by_作者`、下载哈希和重复分隔符。
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

    /// 武器和手持道具。命中后模型归到它的角色下。
    private static let propWords: Set<String> = [
        "武器", "刀", "剑", "槍", "枪", "弓", "扇", "扇子", "伞", "傘", "盾", "杖", "锤", "鎚",
        "斧", "匕首", "双刀", "太刀", "长枪", "道具", "配饰", "配件", "背包", "帽子", "眼镜",
        "面具", "头饰", "饰品", "披风", "尾巴", "翅膀", "宠物", "法杖", "枪械", "弹药", "手持",
        "挂件", "发饰", "耳机", "吉他", "麦克风", "花束", "书", "箱", "球", "棒", "鞭", "镰",
        "拳套", "角", "weapon", "sword", "katana", "gun", "rifle", "prop", "accessory",
        "hat", "glasses", "mask", "bag", "backpack",
    ]

    /// 同一个人*同一角色*的服装与形态。
    private static let variantWords: Set<String> = [
        "白", "黑", "泳装", "泳衣", "死库水", "常服", "私服", "制服", "校服", "战斗服", "礼服",
        "婚纱", "和服", "浴衣", "睡衣", "皮肤", "换色", "异色", "觉醒", "初始", "破损", "战损",
        "改造", "幼年", "成年", "限定", "活动", "新装", "夏装", "冬装", "春装", "秋装", "正装",
        "便服", "工作服", "女仆", "护士", "警服", "军装", "特别版", "默认", "普通",
        "白发", "黑发", "金发", "ver", "ver2", "v2", "alt", "default", "normal",
    ]

    /// 压缩包标题里出现的系列与阵营名。命中就从
    /// 目录名里丢掉，绳匠 因此永远不会变成一个角色。
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

    /// 文件头常常只重复角色名，款式写在文件名里
    /// （`蕾米埃尔_白`）；哪个信息多就留哪个。
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
