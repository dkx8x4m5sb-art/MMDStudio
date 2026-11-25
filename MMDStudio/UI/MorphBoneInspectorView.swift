import SwiftUI

struct MorphInspectorView: View {

    @ObservedObject var document: MMDModelDocument
    @Environment(\.dismiss) private var dismiss

    private var morphIndices: [Int] {
        document.model.morphs.indices.filter {
            document.model.morphs[$0].isVertex || document.model.morphs[$0].isGroup
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if morphIndices.isEmpty {
                    Text("这个模型没有可编辑的顶点或组变形。")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(morphIndices, id: \.self) { index in
                            morphRow(index: index)
                        }
                    } header: {
                        Text("顶点 / 组变形")
                    } footer: {
                        Text("滑杆权重会与 VMD 动作中的变形权重相加。组变形的子项会自动联动。")
                    }
                }
            }
            .navigationTitle("变形")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("全部归零") { document.resetMorphs() }
                        .font(.caption)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func morphRow(index: Int) -> some View {
        let morph = document.model.morphs[index]
        let weight = document.morphWeights.indices.contains(index) ? document.morphWeights[index] : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: morph.isGroup ? "square.stack.3d.up" : "arrow.up.and.down.right.and.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(morph.name)
                    .lineLimit(1)
                Text(morph.panelName)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.14), in: Capsule())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", weight))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: weightBinding(index), in: 0...1)
        }
        .padding(.vertical, 3)
    }

    private func weightBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                document.morphWeights.indices.contains(index)
                    ? Double(document.morphWeights[index])
                    : 0
            },
            set: { value in
                guard document.morphWeights.indices.contains(index) else { return }
                document.morphWeights[index] = Float(max(0, min(1, value)))
            }
        )
    }
}

struct BoneInspectorView: View {

    @ObservedObject var document: MMDModelDocument
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var bindingNotice: String?

    private var filteredBones: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return Array(document.model.bones.indices) }
        return document.model.bones.indices.filter { index in
            let bone = document.model.bones[index]
            return bone.name.lowercased().contains(query) || bone.nameEn.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if document.model.bones.isEmpty {
                    Text("这个模型没有骨骼，将按静态模型渲染。")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        HStack {
                            Text(document.humanoidBindingNote.isEmpty
                                 ? "尚未自动绑定"
                                 : document.humanoidBindingNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("自动绑定") {
                                let count = document.autoBindHumanoid()
                                bindingNotice = "已自动绑定 \(count) 个关节"
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                        Toggle("关节运动约束", isOn: $document.jointConstraintsEnabled)
                            .font(.caption)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(MMDPosePreset.allCases) { preset in
                                    Button(preset.rawValue) {
                                        document.applyPosePreset(preset)
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        ForEach(MMDHumanoidJoint.allCases) { joint in
                            humanoidRow(joint)
                        }
                        if let bindingNotice {
                            Text(bindingNotice)
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    } header: {
                        Text("人体骨骼绑定")
                    } footer: {
                        Text("自动绑定会把 VMD 的标准骨骼名重定向到当前模型的自定义骨架；关节约束只限制异常扭转，不影响正常动作。")
                    }

                    Section {
                        ForEach(filteredBones, id: \.self) { index in
                            NavigationLink {
                                BoneDetailView(document: document, index: index)
                            } label: {
                                boneRow(index: index)
                            }
                        }
                    } header: {
                        Text("共 \(document.model.bones.count) 根骨骼")
                    } footer: {
                        Text("在当前模型中手动旋转骨骼，会覆盖 VMD 对同一根骨骼的旋转；已启用关节约束时会限制异常角度。")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索骨骼名")
            .navigationTitle("骨骼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("全部归零") { document.resetAllBones() }
                        .font(.caption)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func humanoidRow(_ joint: MMDHumanoidJoint) -> some View {
        NavigationLink {
            HumanoidBindingPickerView(document: document, joint: joint)
        } label: {
            HStack {
                Text(joint.label)
                    .font(.caption.weight(.semibold))
                    .frame(width: 52, alignment: .leading)
                if let index = document.humanoidBoneIndex(for: joint) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.model.bones[index].name)
                            .font(.caption)
                            .lineLimit(1)
                        let parent = document.model.bones[index].parentIndex
                        if parent >= 0 && document.model.bones.indices.contains(parent) {
                            Text("父：\(document.model.bones[parent].name)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("未绑定 · 点选手动指定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func boneRow(index: Int) -> some View {
        let bone = document.model.bones[index]
        return HStack(spacing: 8) {
            Circle()
                .fill(document.selectedBoneIndex == index
                      ? Color(red: 1.0, green: 0.62, blue: 0.18)
                      : Color.gray.opacity(0.35))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(bone.name)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if bone.parentIndex >= 0 && bone.parentIndex < document.model.bones.count {
                        Text("父：\(document.model.bones[bone.parentIndex].name)")
                    } else {
                        Text("根骨骼")
                    }
                    if bone.hasIK { Text("IK") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if document.boneRotations[index] != nil {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct HumanoidBindingPickerView: View {
    @ObservedObject var document: MMDModelDocument
    let joint: MMDHumanoidJoint
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var candidates: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return document.model.bones.indices.filter { index in
            if query.isEmpty { return true }
            let bone = document.model.bones[index]
            return bone.name.lowercased().contains(query) || bone.nameEn.lowercased().contains(query)
        }.sorted { lhs, rhs in
            let l = MMDModelDocument.normalizedBoneName(document.model.bones[lhs].name)
            let r = MMDModelDocument.normalizedBoneName(document.model.bones[rhs].name)
            let aliases = joint.aliases.map(MMDModelDocument.normalizedBoneName)
            let ls = aliases.contains(where: { l == $0 || l.contains($0) }) ? 0 : 1
            let rs = aliases.contains(where: { r == $0 || r.contains($0) }) ? 0 : 1
            return ls == rs ? document.model.bones[lhs].name < document.model.bones[rhs].name : ls < rs
        }
    }

    var body: some View {
        List {
            Section {
                Text("为「\(joint.label)」选择实际变形骨。已排除辅助骨不是强制规则，特殊骨架可以手动覆盖自动绑定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if document.humanoidBoneIndex(for: joint) != nil {
                    Button("清除此关节绑定", role: .destructive) {
                        document.setHumanoidBinding(joint, boneIndex: nil)
                        dismiss()
                    }
                }
            }
            Section("候选骨骼（别名优先）") {
                ForEach(candidates, id: \.self) { index in
                    let bone = document.model.bones[index]
                    Button {
                        document.setHumanoidBinding(joint, boneIndex: index)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bone.name).foregroundStyle(.primary)
                                if bone.parentIndex >= 0 && document.model.bones.indices.contains(bone.parentIndex) {
                                    Text("父：\(document.model.bones[bone.parentIndex].name)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if document.humanoidBoneIndex(for: joint) == index {
                                Image(systemName: "checkmark").foregroundStyle(.cyan)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索骨骼或英文名")
        .navigationTitle("绑定 \(joint.label)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct BoneDetailView: View {

    @ObservedObject var document: MMDModelDocument
    let index: Int

    private var bone: PMXBone { document.model.bones[index] }
    private var rotation: SIMD3<Float> { document.boneRotations[index] ?? .zero }

    var body: some View {
        Form {
            Section("骨骼") {
                infoRow("名称", bone.name)
                if !bone.nameEn.isEmpty { infoRow("英文名", bone.nameEn) }
                if bone.parentIndex >= 0 && bone.parentIndex < document.model.bones.count {
                    infoRow("父骨骼", document.model.bones[bone.parentIndex].name)
                } else {
                    infoRow("父骨骼", "无（根骨骼）")
                }
                infoRow("变形层级", "\(bone.layer)")
                infoRow("IK", bone.hasIK ? "有（\(bone.ik?.links.count ?? 0) 个链接）" : "无")
            }

            Section("旋转（度）") {
                rotationSlider("X", axis: 0, color: .red)
                rotationSlider("Y", axis: 1, color: .green)
                rotationSlider("Z", axis: 2, color: .blue)
            }

            Section {
                Button {
                    document.selectedAttachmentID = nil
                    document.selectedLightID = nil
                    document.selectedBoneIndex = index
                    document.sceneEditEnabled = true
                    document.transformMode = .rotate
                } label: {
                    Label("在画布中用旋转 Gizmo 编辑", systemImage: "rotate.3d")
                }
                Button("将此骨骼归零") {
                    document.resetBone(index)
                }
                if bone.hasIK {
                    Text("运行时 IK 已启用：按 PMX 目标骨骼、链接与角度限制做 CCD 迭代；可在设置中关闭以查看原始 FK。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("数值为 0 时不会写入手动姿态，VMD 旋转会直接生效。双击模型视图可重置相机。")
            }
        }
        .navigationTitle(bone.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { document.selectedBoneIndex = index }
    }

    private func rotationSlider(_ title: String, axis: Int, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 16)
            Slider(value: rotationBinding(axis: axis), in: -180...180, step: 1)
            Text(String(format: "%.0f°", rotation[axis]))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func rotationBinding(axis: Int) -> Binding<Double> {
        Binding(
            get: { Double(rotation[axis]) },
            set: { value in
                var euler = rotation
                euler[axis] = Float(value)
                document.setBoneRotation(index: index, degrees: euler)
            }
        )
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
