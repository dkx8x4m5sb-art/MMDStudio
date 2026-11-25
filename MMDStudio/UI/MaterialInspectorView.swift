import SwiftUI

struct MaterialInspectorView: View {

    @ObservedObject var document: MMDModelDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if document.materialSettings.isEmpty {
                    Text("这个模型没有材质。")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(document.materialSettings) { settings in
                            NavigationLink {
                                MaterialDetailView(document: document, index: settings.id)
                            } label: {
                                materialRow(settings)
                            }
                        }
                    } header: {
                        Text("共 \(document.materialSettings.count) 个材质")
                    } footer: {
                        Text("点按材质可编辑颜色、透明度、描边与球面贴图。")
                    }
                }
            }
            .navigationTitle("材质")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("恢复默认") { document.resetMaterialSettings() }
                        .font(.caption)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func materialRow(_ settings: MMDMaterialSettings) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(simd4: settings.diffuse))
                .frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.2)))
            VStack(alignment: .leading, spacing: 2) {
                Text(document.model.materials[settings.id].name)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !settings.useTexture { badge("无贴图") }
                    if settings.doubleSided { badge("双面") }
                    if !settings.visible { badge("隐藏") }
                }
            }
            Spacer()
            if !settings.visible {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.gray.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

struct MaterialDetailView: View {

    @ObservedObject var document: MMDModelDocument
    let index: Int

    private var settings: MMDMaterialSettings { document.materialSettings[index] }
    private var material: PMXMaterial { document.model.materials[index] }

    var body: some View {
        Form {
            if document.materialSettings.indices.contains(index) {
                Section("外观") {
                    ColorPicker("漫反射颜色",
                                selection: colorBinding(\.diffuse),
                                supportsOpacity: false)
                    HStack {
                        Text("不透明度")
                        Slider(value: opacityBinding, in: 0...1)
                        Text(String(format: "%.0f%%", settings.diffuse.w * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    Toggle("显示", isOn: boolBinding(\.visible))
                    Toggle("双面绘制", isOn: boolBinding(\.doubleSided))
                    Toggle("投射地面阴影", isOn: boolBinding(\.castsShadow))
                }

                Section("贴图") {
                    Toggle("使用基础贴图", isOn: boolBinding(\.useTexture))
                        .disabled(material.textureIndex < 0)
                    Toggle("使用卡通渐变", isOn: boolBinding(\.useToon))
                    Picker("球面贴图", selection: sphereModeBinding) {
                        Text("无").tag(0)
                        Text("乘法").tag(1)
                        Text("加法").tag(2)
                        Text("加法·子贴图").tag(3)
                    }
                    .disabled(material.sphereIndex < 0)
                    if material.sphereIndex < 0 {
                        Text("该材质没有球面贴图。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("描边") {
                    Toggle("启用描边", isOn: boolBinding(\.hasEdge))
                    ColorPicker("描边颜色", selection: colorBinding(\.edgeColor), supportsOpacity: false)
                    HStack {
                        Text("宽度")
                        Slider(value: edgeSizeBinding, in: 0...5)
                        Text(String(format: "%.2f", settings.edgeSize))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }

                Section("材质信息") {
                    infoRow("英文名", material.nameEn.isEmpty ? "—" : material.nameEn)
                    infoRow("基础贴图索引", material.textureIndex >= 0 ? "\(material.textureIndex)" : "无")
                    infoRow("球面模式", "\(material.sphereMode)")
                    infoRow("绘制标志", String(format: "0x%02X", UInt32(material.drawFlags)))
                    infoRow("面索引数", "\(material.indexCount)")
                    if !material.memo.isEmpty {
                        infoRow("备注", material.memo)
                    }
                }

                Section {
                    Button("恢复此材质默认值") {
                        document.materialSettings[index] = MMDMaterialSettings(material: material, index: index)
                    }
                }
            } else {
                Text("材质索引无效")
            }
        }
        .navigationTitle(material.name)
        .navigationBarTitleDisplayMode(.inline)
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

    private func colorBinding(_ keyPath: WritableKeyPath<MMDMaterialSettings, SIMD4<Float>>) -> Binding<Color> {
        Binding(
            get: {
                guard document.materialSettings.indices.contains(index) else { return .white }
                return Color(simd4: document.materialSettings[index][keyPath: keyPath])
            },
            set: { value in
                guard document.materialSettings.indices.contains(index) else { return }
                document.materialSettings[index][keyPath: keyPath] = value.simd4
            }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<MMDMaterialSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: {
                guard document.materialSettings.indices.contains(index) else { return false }
                return document.materialSettings[index][keyPath: keyPath]
            },
            set: { value in
                guard document.materialSettings.indices.contains(index) else { return }
                document.materialSettings[index][keyPath: keyPath] = value
            }
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: {
                guard document.materialSettings.indices.contains(index) else { return 1 }
                return Double(document.materialSettings[index].diffuse.w)
            },
            set: { value in
                guard document.materialSettings.indices.contains(index) else { return }
                document.materialSettings[index].diffuse.w = Float(value)
            }
        )
    }

    private var edgeSizeBinding: Binding<Double> {
        Binding(
            get: {
                guard document.materialSettings.indices.contains(index) else { return 1 }
                return Double(document.materialSettings[index].edgeSize)
            },
            set: { value in
                guard document.materialSettings.indices.contains(index) else { return }
                document.materialSettings[index].edgeSize = Float(value)
            }
        )
    }

    private var sphereModeBinding: Binding<Int> {
        Binding(
            get: {
                guard document.materialSettings.indices.contains(index) else { return 0 }
                return Int(document.materialSettings[index].sphereMode)
            },
            set: { value in
                guard document.materialSettings.indices.contains(index) else { return }
                document.materialSettings[index].sphereMode = UInt8(value)
            }
        )
    }
}
