//
//  MMDMetalView.swift
//  MMD Studio
//
//  Metal 视图的 UIKit 桥接与手势、通知绑定。
//

import SwiftUI
import MetalKit
import UIKit
import Photos

struct MMDMetalView: UIViewRepresentable {

    @ObservedObject var document: MMDModelDocument

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MMDGestureView {
        let container = MMDGestureView(frame: .zero)
        container.backgroundColor = .black

        guard let renderer = MMDRenderer(view: container.renderView) else {
            return container
        }
        context.coordinator.renderer = renderer
        MMDRenderer.active = renderer
        renderer.document = document
        renderer.onRenderScaleChange = { [weak container] scale in
            container?.renderScale = scale
        }

        container.onOrbit = { [weak renderer] deltaX, deltaY in
            if document.sceneEditEnabled {
                renderer?.transformSelection(deltaX: deltaX, deltaY: deltaY)
            } else {
                renderer?.orbitCamera(deltaX: deltaX, deltaY: deltaY)
            }
        }
        container.onPan = { [weak renderer] deltaX, deltaY in
            renderer?.panCamera(deltaX: deltaX, deltaY: deltaY)
        }
        container.onZoom = { [weak renderer] scale in
            renderer?.zoomCamera(scale: scale)
        }
        container.onReset = { [weak renderer] in
            renderer?.resetCamera()
        }

        context.coordinator.observe(.mmdResetCamera) { [weak renderer] _ in
            renderer?.resetCamera()
        }
        context.coordinator.observe(.mmdCapturePhoto) { [weak renderer] note in
            // 渲染器在回读 blit 之前会先关闭渲染编码器；
            // 更高的倍率临时放大 drawable，保存下来的是
            // 渲染静帧，而不是屏幕 UI 截图。
            guard let renderer else {
                NotificationCenter.default.post(name: .mmdPhotoCaptured, object: false)
                return
            }
            let scale = CGFloat((note.object as? NSNumber)?.floatValue ?? 1)
            renderer.capturePhoto(scale: scale) { image in
                if let image {
                    MMDMetalView.savePhoto(image)
                } else {
                    NotificationCenter.default.post(name: .mmdPhotoCaptured, object: false)
                }
            }
        }
        context.coordinator.observe(.mmdStartEngineCapture) { [weak renderer] _ in
            renderer?.setEngineCaptureHandler { data, width, height, rowBytes in
                MMDScreenRecorder.shared.append(frame: data, width: width,
                                                height: height, bytesPerRow: rowBytes)
            }
        }
        context.coordinator.observe(.mmdStopEngineCapture) { [weak renderer] _ in
            renderer?.setEngineCaptureHandler(nil)
        }
        return container
    }

    private static func savePhoto(_ image: UIImage) {
        let finish: (Bool) -> Void = { ok in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .mmdPhotoCaptured, object: ok)
            }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                MMDLog.shared.error("Photo save denied, status=\(status.rawValue)")
                finish(false)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                if let error {
                    MMDLog.shared.error("Photo save failed: \(error.localizedDescription)")
                } else {
                    MMDLog.shared.info("Render saved: \(Int(image.size.width))x\(Int(image.size.height))")
                }
                finish(success)
            }
        }
    }

    func updateUIView(_ uiView: MMDGestureView, context: Context) {
        context.coordinator.renderer?.document = document
    }

    static func dismantleUIView(_ uiView: MMDGestureView, coordinator: Coordinator) {
        uiView.renderView.delegate = nil
        coordinator.removeAllObservers()
        coordinator.renderer?.setEngineCaptureHandler(nil)
    }

    final class Coordinator {
        var renderer: MMDRenderer?
        private var observers: [NSObjectProtocol] = []

        /// 画布需要的通知都从这里登记，销毁时一次性撤销。
        /// 之前每个通知各占一个字段、各写一段 remove，加一个通知要改三处。
        func observe(_ name: Notification.Name, handler: @escaping (Notification) -> Void) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil,
                                                                   queue: .main, using: handler))
        }

        func removeAllObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        deinit {
            removeAllObservers()
        }
    }
}

/// 承载 MTKView 并管理相机手势的 UIKit 容器。
final class MMDGestureView: UIView, UIGestureRecognizerDelegate {

    let renderView: MTKView
    var onOrbit: ((Float, Float) -> Void)?
    var onPan: ((Float, Float) -> Void)?
    var onZoom: ((Float) -> Void)?
    var onReset: (() -> Void)?

    /// 1.0 按原生分辨率渲染。GPU 预算超了时
    /// 渲染器会降低它，但不改 UI 布局。
    var renderScale: CGFloat = 1.0 {
        didSet {
            guard abs(oldValue - renderScale) > 0.001 else { return }
            updateDrawableSize()
        }
    }

    override init(frame: CGRect) {
        renderView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        super.init(frame: frame)
        clipsToBounds = true
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        renderView.translatesAutoresizingMaskIntoConstraints = true
        renderView.autoResizeDrawable = false
        renderView.framebufferOnly = false
        renderView.isOpaque = true
        addSubview(renderView)
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderView.frame = bounds
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let nativeScale = UIScreen.main.scale
        let width = max(1, Int(bounds.width * nativeScale * renderScale))
        let height = max(1, Int(bounds.height * nativeScale * renderScale))
        let size = CGSize(width: width, height: height)
        if renderView.drawableSize != size {
            renderView.drawableSize = size
        }
    }

    private func setupGestures() {
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        addGestureRecognizer(orbit)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        for recognizer in gestureRecognizers ?? [] {
            recognizer.delegate = self
        }

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        // 渲染器按视口尺寸把点换算成弧度。
        onOrbit?(Float(translation.x), Float(translation.y))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        onPan?(Float(translation.x), Float(translation.y))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        onZoom?(Float(gesture.scale))
        gesture.scale = 1
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        onReset?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
