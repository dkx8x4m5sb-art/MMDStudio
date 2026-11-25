import Foundation
import Metal
import MetalKit
import QuartzCore
import UIKit
import simd

struct MMDDrawVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

private final class MMDAttachmentRenderItem {
    let id: UUID
    let model: PMXModel
    let mesh: MMDMesh
    let skeleton: MMDSkeleton
    let materialSettings: [MMDMaterialSettings]
    let baseDirectory: URL
    let fallbackRoot: URL?
    var paletteBuffer: MTLBuffer?
    var paletteCapacity = 0
    let physics = MMDSpringPhysics()

    init(attachment: MMDAttachment, mesh: MMDMesh) {
        id = attachment.id
        model = attachment.model
        self.mesh = mesh
        skeleton = MMDSkeleton(model: attachment.model)
        materialSettings = attachment.model.materials.enumerated().map {
            MMDMaterialSettings(material: $0.element, index: $0.offset)
        }
        baseDirectory = attachment.baseDirectory
        fallbackRoot = attachment.fallbackRoot
        physics.prepare(model: attachment.model)
    }
}

final class MMDRenderer: NSObject, MTKViewDelegate {

    static weak var active: MMDRenderer?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private weak var view: MTKView?
    weak var document: MMDModelDocument?

    private var meshOpaquePipeline: MTLRenderPipelineState!
    private var meshTransparentPipeline: MTLRenderPipelineState!
    private var edgePipeline: MTLRenderPipelineState!
    private var contactShadowPipeline: MTLRenderPipelineState!
    private var backdropPipeline: MTLRenderPipelineState!
    private var backdropImagePipeline: MTLRenderPipelineState!
    private var backdropTextureCache: [String: MTLTexture] = [:]
    private var gridPipeline: MTLRenderPipelineState!
    private var overlayPipeline: MTLRenderPipelineState!

    private var opaqueDepthState: MTLDepthStencilState!
    private var overlayDepthState: MTLDepthStencilState!
    private var gizmoDepthState: MTLDepthStencilState!
    private var shadowDepthState: MTLDepthStencilState!

    private var mesh: MMDMesh?
    private var skeleton: MMDSkeleton?
    private var textures: MMDTextureLibrary?
    private var baseDirectory: URL?
    private var fallbackRoot: URL?
    private var loadedRevision = -1
    private var loadedDocumentID: ObjectIdentifier?
    private var loadedUVFlip = false
    private var loadedSceneRevision = -1
    private var attachmentItems: [UUID: MMDAttachmentRenderItem] = [:]
    private var currentPose: MMDSkeletonPose?
    private var lastMorphWeights: [Float] = []
    /// Rest positions and the working morph buffer. `MMDMorphController.positions`
    /// used to allocate two full vertex arrays per change; on a 40k-vertex model
    /// that is a megabyte of churn every time an expression slider moves.
    private var basePositions: [SIMD3<Float>] = []
    private var morphedPositions: [SIMD3<Float>] = []
    private var resolvedWeightsScratch: [Float] = []
    private var groupAdditionsScratch: [Float] = []

    var camera = MMDOrbitCamera()
    var onRenderScaleChange: ((CGFloat) -> Void)?
    private var autoOrbitEnabled = false
    private var lastAutoOrbitTime: CFTimeInterval = 0

    private var photoCompletion: ((UIImage?) -> Void)?
    private var photoPending = false
    private var photoRestoreScale: CGFloat?
    private var engineCaptureHandler: ((Data, Int, Int, Int) -> Void)?
    private var lastEngineCaptureTime: CFTimeInterval = 0
    private let engineCaptureInterval: CFTimeInterval = 1.0 / 30.0

    private var renderScale: CGFloat = 1.0

    /// Reusable offscreen render targets. Allocating three textures per frame
    /// (MSAA colour, resolve, depth) cost tens of megabytes at 4K and was the
    /// main reason exports could not reach the requested frame rate.
    private struct CaptureTargets {
        let width: Int
        let height: Int
        let sampleCount: Int
        let resolve: MTLTexture
        let msaa: MTLTexture?
        let depth: MTLTexture
    }
    private var cachedCaptureTargets: CaptureTargets?
    private var appliedQuality: MMDQualityMode?
    private var lastQualityCheck = CACurrentMediaTime()
    private var lastAdaptiveChange = CACurrentMediaTime()

    private let statsLock = NSLock()
    private var statsWindowStart = CACurrentMediaTime()
    private var statsFrames = 0
    private var statsCPUSum: Double = 0
    private var statsGPUSum: Double = 0
    private var statsDrawSum = 0
    private var statsTriangleSum = 0
    private var lastDrawCalls = 0
    private var lastTriangles = 0

    private var gridBuffer: MTLBuffer?
    private var gridVertexCount = 0
    private var groundShadowBuffer: MTLBuffer?
    private var groundShadowVertexCount = 0

    private var overlayBuffer: MTLBuffer?
    private var overlayCapacity = 0
    private var overlayAllocated = 0

    private var paletteBuffer: MTLBuffer?
    private var paletteCapacity = 0

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.view = view

        super.init()

        view.device = device
        // Engine recording blits the resolved drawable into a shared buffer.
        // The default framebuffer-only drawable makes that blit illegal.
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.preferredFramesPerSecond = max(60, UIScreen.main.maximumFramesPerSecond)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColor(red: 0.1, green: 0.11, blue: 0.14, alpha: 1)
        view.delegate = self

        do {
            try buildPipelines(sampleCount: view.sampleCount)
        } catch {
            assertionFailure("Metal pipeline creation failed: \(error)")
            return nil
        }
        textures = MMDTextureLibrary(device: device, commandQueue: queue)
    }

    // MARK: - Pipeline setup

    private func buildPipelines(sampleCount: Int) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MMDLoadError.io("找不到默认 Metal 着色器库，请确认 Shaders.metal 已加入目标")
        }

        func makePipeline(_ vertex: String, _ fragment: String,
                          blending: Bool,
                          sampleCount: Int) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.rasterSampleCount = sampleCount
            if blending {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        meshOpaquePipeline = try makePipeline("mmd_mesh_vertex", "mmd_mesh_fragment", blending: false, sampleCount: sampleCount)
        meshTransparentPipeline = try makePipeline("mmd_mesh_vertex", "mmd_mesh_fragment", blending: true, sampleCount: sampleCount)
        edgePipeline = try makePipeline("mmd_edge_vertex", "mmd_edge_fragment", blending: false, sampleCount: sampleCount)
        contactShadowPipeline = try makePipeline("mmd_contact_shadow_vertex", "mmd_contact_shadow_fragment", blending: true, sampleCount: sampleCount)
        backdropPipeline = try makePipeline("mmd_backdrop_vertex", "mmd_backdrop_fragment", blending: false, sampleCount: sampleCount)
        backdropImagePipeline = try makePipeline("mmd_backdrop_vertex", "mmd_backdrop_image_fragment", blending: false, sampleCount: sampleCount)
        gridPipeline = try makePipeline("mmd_grid_vertex", "mmd_grid_fragment", blending: true, sampleCount: sampleCount)
        overlayPipeline = try makePipeline("mmd_overlay_vertex", "mmd_overlay_fragment", blending: true, sampleCount: sampleCount)

        let opaque = MTLDepthStencilDescriptor()
        opaque.depthCompareFunction = .lessEqual
        opaque.isDepthWriteEnabled = true
        opaqueDepthState = device.makeDepthStencilState(descriptor: opaque)

        let overlay = MTLDepthStencilDescriptor()
        overlay.depthCompareFunction = .lessEqual
        overlay.isDepthWriteEnabled = false
        overlayDepthState = device.makeDepthStencilState(descriptor: overlay)

        let gizmo = MTLDepthStencilDescriptor()
        gizmo.depthCompareFunction = .always
        gizmo.isDepthWriteEnabled = false
        gizmoDepthState = device.makeDepthStencilState(descriptor: gizmo)

        let shadow = MTLDepthStencilDescriptor()
        shadow.depthCompareFunction = .lessEqual
        shadow.isDepthWriteEnabled = false
        shadowDepthState = device.makeDepthStencilState(descriptor: shadow)
    }

    // MARK: - Document loading

    private func reloadIfNeeded() {
        guard let document else { return }
        let model = document.model
        let identifier = ObjectIdentifier(document)
        let flipV = document.renderSettings.uvFlipV
        if loadedRevision == document.modelRevision && loadedDocumentID == identifier
            && loadedUVFlip == flipV && loadedSceneRevision == document.sceneRevision {
            return
        }

        let isDocumentChange = loadedDocumentID != identifier
        if isDocumentChange { attachmentItems.removeAll() }
        do {
            let mesh = try MMDMeshBuilder(device: device).build(model: model, flipV: flipV)
            self.mesh = mesh
            self.skeleton = MMDSkeleton(model: model)
            basePositions = model.vertices.map { $0.position }
            morphedPositions = basePositions
            resolvedWeightsScratch = [Float](repeating: 0, count: model.morphs.count)
            baseDirectory = document.baseDirectory
            fallbackRoot = document.fallbackRoot
            loadedRevision = document.modelRevision
            loadedDocumentID = identifier
            loadedUVFlip = flipV
            lastMorphWeights = []
            if isDocumentChange {
                camera.fit(bounds: mesh.bounds)
                rebuildGroundOverlays(bounds: mesh.bounds)
            }
            refreshMorphPositions(document: document, model: model,
                                  frame: document.currentFrame, force: true)
            reloadAttachments(document: document)
            loadedSceneRevision = document.sceneRevision
            textureCacheWillChange()
        } catch {
            mesh = nil
            document.errorMessage = error.localizedDescription
            loadedRevision = document.modelRevision
            loadedDocumentID = identifier
        }
    }

    private func reloadAttachments(document: MMDModelDocument) {
        let activeIDs = Set(document.attachments.map(\.id))
        attachmentItems = attachmentItems.filter { activeIDs.contains($0.key) }
        for attachment in document.attachments where attachmentItems[attachment.id] == nil {
            do {
                let mesh = try MMDMeshBuilder(device: device).build(model: attachment.model,
                                                                    flipV: document.renderSettings.uvFlipV)
                attachmentItems[attachment.id] = MMDAttachmentRenderItem(attachment: attachment, mesh: mesh)
                MMDLog.shared.info("Attachment mesh ready: \(attachment.name), triangles=\(mesh.subMeshes.reduce(0) { $0 + $1.indexCount / 3 })", category: "Scene")
            } catch {
                MMDLog.shared.error("Attachment mesh failed: \(attachment.name): \(error.localizedDescription)", category: "Scene")
            }
        }
    }

    private func textureCacheWillChange() {
        // The texture library is intentionally retained across draws, but a
        // new mesh/base directory invalidates all resolved paths.
        textures?.clearCache()
    }

    private func drawBackdrop(encoder: MTLRenderCommandEncoder,
                              settings: MMDRenderSettings,
                              aspect: Float,
                              document: MMDModelDocument) {
        if let path = settings.backgroundImagePath, !path.isEmpty,
           let texture = backdropTexture(path: path) {
            encoder.setRenderPipelineState(backdropImagePipeline)
            encoder.setDepthStencilState(overlayDepthState)
            var params = SIMD4<Float>(Float(texture.width) / Float(max(1, texture.height)),
                                      aspect, 0, 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            return
        }
        encoder.setRenderPipelineState(backdropPipeline)
        encoder.setDepthStencilState(overlayDepthState)
        var backdrop = makeBackdrop(document: document)
        encoder.setFragmentBytes(&backdrop, length: MemoryLayout<MMDStudioBackdropUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func backdropTexture(path: String) -> MTLTexture? {
        if let cached = backdropTextureCache[path] { return cached }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path),
              let texture = textures?.loadFileTexture(url: url) else { return nil }
        backdropTextureCache[path] = texture
        return texture
    }

    // MARK: - Capture

    /// Drives one deterministic frame for the offline video exporter. The
    /// document is advanced on the main thread because all render state is
    /// main-thread owned, while the caller may wait on a background queue.
    func captureFrame(frame: Float, width: Int, height: Int,
                      transparentBackground: Bool? = nil,
                      preferMSAA: Bool = false,
                      completion: @escaping (UIImage?) -> Void) {
        // A synchronous hop avoids the async + semaphore round trip per frame,
        // which dominated export time at 4K. captureStill already blocks until
        // the GPU finishes, so callers stay sequential.
        let work: () -> Void = { [weak self] in
            guard let self, let document = self.document else { completion(nil); return }
            document.currentFrame = max(0, min(document.duration, frame))
            self.captureStill(width: width, height: height,
                              transparentOverride: transparentBackground,
                              preferMSAA: preferMSAA,
                              completion: completion)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    func restoreFrame(_ frame: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = self.document else { return }
            document.currentFrame = max(0, min(document.duration, frame))
            document.resetPhysics()
        }
    }

    /// Captures an offscreen Metal render at an explicit pixel size. Unlike
    /// the old drawable readback, this is independent from the on-screen
    /// viewport, so the result is a real high-resolution render rather than
    /// an upscaled screen capture.
    func capturePhoto(scale: CGFloat = 1, completion: @escaping (UIImage?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { completion(nil); return }
            let settings = self.document?.renderSettings
            let width = settings?.photoWidth ?? Int(1440 * max(1, scale))
            let height = settings?.photoHeight ?? Int(2560 * max(1, scale))
            self.captureStill(width: width, height: height, completion: completion)
        }
    }

    private func restorePhotoScale() {
        guard let previous = photoRestoreScale else { return }
        photoRestoreScale = nil
        renderScale = previous
        onRenderScaleChange?(previous)
    }

    private func captureStill(width requestedWidth: Int, height requestedHeight: Int,
                              transparentOverride: Bool? = nil,
                              preferMSAA: Bool = true,
                              completion: @escaping (UIImage?) -> Void) {
        reloadIfNeeded()
        guard let document, let mesh, let skeleton, let textures else {
            completion(nil)
            return
        }

        let width = max(64, min(4096, requestedWidth))
        let height = max(64, min(4096, requestedHeight))
        let model = document.model
        refreshMorphPositions(document: document, model: model,
                              frame: document.currentFrame, force: true)

        let animations = document.effectiveBoneAnimations(frame: document.currentFrame)
        let pose = skeleton.solve(animations: animations, model: model, ikEnabled: document.ikEnabled)
        currentPose = pose

        let aspect = Float(width) / Float(max(1, height))
        let eye: SIMD3<Float>
        let target: SIMD3<Float>
        let fovDegrees: Float
        if document.useCameraMotion, let motion = document.motion, !motion.cameraKeys.isEmpty,
           let cameraPose = VMDMotion.evaluateCamera(keys: motion.cameraKeys,
                                                     frame: document.currentFrame) {
            eye = cameraPose.eye
            target = cameraPose.target
            fovDegrees = cameraPose.fovDegrees
        } else {
            eye = camera.eye
            target = camera.target
            fovDegrees = camera.fovDegrees
        }

        let radius = max(mesh.bounds.radius, 0.5)
        let near = max(0.02, min(camera.distance * 0.02, radius * 0.2))
        let far = max(radius * 8, camera.distance + radius * 6) + 50
        let viewMatrix = mmdLookAt(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
        let projection = mmdPerspective(fovYRadians: mmdRadians(fovDegrees),
                                        aspect: aspect, near: near, far: far)

        var scene = MMDSceneUniforms()
        scene.viewProjection = projection * viewMatrix
        scene.view = viewMatrix
        scene.model = matrix_identity_float4x4
        scene.normalMatrix = matrix_identity_float4x4
        let lightSettings = document.renderSettings
        let activeLights = Array(lightSettings.lights.filter(\.enabled).prefix(8))
        var lightUniforms = activeLights.map { $0.uniform }
        while lightUniforms.count < 8 { lightUniforms.append(.zero) }
        scene.lights = (lightUniforms[0], lightUniforms[1], lightUniforms[2], lightUniforms[3],
                        lightUniforms[4], lightUniforms[5], lightUniforms[6], lightUniforms[7])
        scene.lightCount = SIMD4<Float>(Float(activeLights.count),
                                        max(0.05, min(1.0, lightSettings.lightAmbient)),
                                        max(0.5, min(2.0, lightSettings.exposure)),
                                        max(2.0, min(5.0, lightSettings.style.toonSteps)))
        if let firstSun = lightSettings.lights.first(where: { $0.kind == .sun && $0.enabled }) {
            let direction = simd_length(firstSun.direction) > 0.0001
                ? simd_normalize(firstSun.direction)
                : SIMD3<Float>(0.4, 0.8, 0.5)
            scene.lightDirection = SIMD4<Float>(direction.x, direction.y, direction.z, 0)
            scene.lightColor = SIMD4<Float>(firstSun.color.x * firstSun.intensity,
                                            firstSun.color.y * firstSun.intensity,
                                            firstSun.color.z * firstSun.intensity, 1)
        } else {
            scene.lightDirection = SIMD4<Float>(0.4, 0.8, 0.5, 0)
            scene.lightColor = SIMD4<Float>(0.95, 0.95, 1.0, 1)
        }
        scene.ambientColor = SIMD4<Float>(0.18, 0.18, 0.21,
                                          max(0.55, min(1.75, lightSettings.saturation)))
        scene.lightParams = SIMD4<Float>(max(0.05, min(1.0, lightSettings.lightAmbient)),
                                         max(0.0, min(1.0, lightSettings.lightFill)),
                                         max(0.0, min(1.0, lightSettings.lightRim)),
                                         max(0.5, min(2.0, lightSettings.exposure)))
        scene.cameraPosition = SIMD4<Float>(eye.x, eye.y, eye.z, 1)
        let groundY = mesh.bounds.minPoint.y
        let gridSpacing = max(0.05, mesh.bounds.height / 20)
        scene.params = SIMD4<Float>(groundY + 0.002, gridSpacing,
                                    lightSettings.edgeScale, lightSettings.style.index)
        scene.viewportSize = SIMD4<Float>(Float(width), Float(height), 0, 0)
        scene.gradeParams = SIMD4<Float>(max(0.70, min(1.60, lightSettings.contrast)),
                                         max(0.0, min(2.0, lightSettings.bloom)),
                                         max(0.0, min(1.4, lightSettings.vignette)),
                                         max(0.0, min(2.0, lightSettings.reflection)))
        scene.toonParams = SIMD4<Float>(max(0.0, min(0.45, lightSettings.toonSoftness)),
                                        max(0.0, min(1.0, lightSettings.toonShadowLift)),
                                        max(0.0, min(1.0, lightSettings.toonRim)), 0)
        scene.toonShadowTint = lightSettings.toonShadowTint
        scene.worldParams = SIMD4<Float>(max(0, lightSettings.worldScattering),
                                         max(0, lightSettings.worldIntensity), 0, 0)
        scene.worldSkyColor = lightSettings.worldSkyColor
        scene.worldGroundColor = lightSettings.worldGroundColor

        // Video frames skip MSAA: 4× at 4K was the single largest GPU cost and
        // the encoder's own filtering masks the difference.
        let sampleCount = preferMSAA ? max(1, view?.sampleCount ?? 4) : 1
        let targets: CaptureTargets
        if let cached = cachedCaptureTargets,
           cached.width == width, cached.height == height, cached.sampleCount == sampleCount {
            targets = cached
        } else {
            let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
            colorDescriptor.usage = [.renderTarget, .shaderRead]
            colorDescriptor.storageMode = .shared
            let depthDescriptor = MTLTextureDescriptor()
            if sampleCount > 1 {
                depthDescriptor.textureType = .type2DMultisample
                depthDescriptor.sampleCount = sampleCount
            } else {
                depthDescriptor.textureType = .type2D
            }
            depthDescriptor.pixelFormat = .depth32Float
            depthDescriptor.width = width
            depthDescriptor.height = height
            depthDescriptor.usage = .renderTarget
            depthDescriptor.storageMode = .private

            guard let resolve = device.makeTexture(descriptor: colorDescriptor),
                  let depth = device.makeTexture(descriptor: depthDescriptor) else {
                completion(nil)
                return
            }
            var msaa: MTLTexture?
            if sampleCount > 1 {
                let msaaDescriptor = MTLTextureDescriptor()
                msaaDescriptor.textureType = .type2DMultisample
                msaaDescriptor.pixelFormat = .bgra8Unorm_srgb
                msaaDescriptor.width = width
                msaaDescriptor.height = height
                msaaDescriptor.sampleCount = sampleCount
                msaaDescriptor.usage = .renderTarget
                msaaDescriptor.storageMode = .private
                guard let texture = device.makeTexture(descriptor: msaaDescriptor) else {
                    completion(nil)
                    return
                }
                msaa = texture
            }
            targets = CaptureTargets(width: width, height: height, sampleCount: sampleCount,
                                     resolve: resolve, msaa: msaa, depth: depth)
            cachedCaptureTargets = targets
        }
        let resolveTexture = targets.resolve
        let msaaColor = targets.msaa
        let depthTexture = targets.depth

        let pass = MTLRenderPassDescriptor()
        if sampleCount > 1 {
            pass.colorAttachments[0].texture = msaaColor
            pass.colorAttachments[0].resolveTexture = resolveTexture
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = resolveTexture
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        let transparent = transparentOverride ?? lightSettings.photoTransparentBackground
        if transparent {
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        } else {
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(lightSettings.backgroundColor.x),
                green: Double(lightSettings.backgroundColor.y),
                blue: Double(lightSettings.backgroundColor.z), alpha: 1)
        }
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            completion(nil)
            return
        }

        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(width), height: Double(height),
                                        znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setFrontFacing(mesh.frontWinding)
        encoder.setTriangleFillMode(.fill)

        if !transparent {
            drawBackdrop(encoder: encoder, settings: lightSettings, aspect: aspect, document: document)
        }

        if lightSettings.photoIncludeGrid, let gridBuffer, gridVertexCount > 0 {
            encoder.setRenderPipelineState(gridPipeline)
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            setScene(scene, encoder: encoder, vertexIndex: 1)
            var sceneForFragment = scene
            encoder.setFragmentBytes(&sceneForFragment, length: MemoryLayout<MMDSceneUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gridVertexCount)
        }
        encoder.setTriangleFillMode(lightSettings.renderMode == .wireframe ? .lines : .fill)

        if lightSettings.showGroundShadow,
           let groundShadowBuffer, groundShadowVertexCount > 0 {
            encoder.setRenderPipelineState(contactShadowPipeline)
            encoder.setDepthStencilState(shadowDepthState)
            encoder.setVertexBuffer(groundShadowBuffer, offset: 0, index: 0)
            setScene(scene, encoder: encoder, vertexIndex: 1)
            encoder.setCullMode(.none)
            encoder.setTriangleFillMode(.fill)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: groundShadowVertexCount)
            encoder.setTriangleFillMode(lightSettings.renderMode == .wireframe ? .lines : .fill)
        }

        encoder.setRenderPipelineState(meshOpaquePipeline)
        encoder.setDepthStencilState(opaqueDepthState)
        bindMeshBuffers(encoder, mesh: mesh)
        setScene(scene, encoder: encoder, vertexIndex: 6)
        if let paletteBuffer = updatePaletteBuffer(pose.palettes) {
            encoder.setVertexBuffer(paletteBuffer, offset: 0, index: 7)
        }
        encoder.setFragmentBytes(&scene, length: MemoryLayout<MMDSceneUniforms>.stride, index: 0)

        for submesh in mesh.subMeshes {
            let materialIndex = submesh.materialIndex
            guard document.materialSettings.indices.contains(materialIndex) else { continue }
            let settings = document.materialSettings[materialIndex]
            guard settings.visible, settings.diffuse.w >= 0.999 else { continue }
            let material = model.materials[materialIndex]
            let baseTexture = (settings.useTexture && material.textureIndex >= 0)
                ? textures.embeddedOrFallback(index: material.textureIndex, model: model,
                                              baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
                : textures.whiteTexture
            let sphereTexture = (material.sphereIndex >= 0 && settings.sphereMode != 0)
                ? textures.embeddedOrFallback(index: material.sphereIndex, model: model,
                                              baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
                : textures.whiteTexture
            let toonTexture = textures.toonTexture(for: material, model: model,
                                                   baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
            encoder.setFragmentTexture(baseTexture, index: 0)
            encoder.setFragmentTexture(sphereTexture, index: 1)
            encoder.setFragmentTexture(toonTexture, index: 2)
            var uniforms = makeMaterialUniforms(document: document, materialIndex: materialIndex,
                                                transparent: false, flags: 0,
                                                texturePresent: settings.useTexture && material.textureIndex >= 0,
                                                spherePresent: material.sphereIndex >= 0 && settings.sphereMode != 0,
                                                toonPresent: settings.useToon)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: 1)
            encoder.setCullMode(settings.doubleSided ? .none : .back)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: submesh.indexCount,
                                          indexType: .uint32,
                                          indexBuffer: mesh.indexBuffer,
                                          indexBufferOffset: submesh.indexBufferOffset)
        }

        if lightSettings.edgesEnabled, lightSettings.renderMode.usesEdges {
            encoder.setRenderPipelineState(edgePipeline)
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setDepthBias(0.0006, slopeScale: 1.2, clamp: 0)
            bindMeshBuffers(encoder, mesh: mesh)
            setScene(scene, encoder: encoder, vertexIndex: 6)
            if let paletteBuffer = updatePaletteBuffer(pose.palettes) {
                encoder.setVertexBuffer(paletteBuffer, offset: 0, index: 8)
            }
            encoder.setCullMode(.front)
            for submesh in mesh.subMeshes {
                let materialIndex = submesh.materialIndex
                guard document.materialSettings.indices.contains(materialIndex) else { continue }
                let settings = document.materialSettings[materialIndex]
                guard settings.visible, settings.hasEdge, settings.edgeSize > 0,
                      settings.diffuse.w >= 0.999 else { continue }
                var uniforms = makeMaterialUniforms(document: document, materialIndex: materialIndex,
                                                    transparent: false, flags: 0,
                                                    texturePresent: false, spherePresent: false, toonPresent: false)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: 7)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle,
                                              indexCount: submesh.indexCount,
                                              indexType: .uint32,
                                              indexBuffer: mesh.indexBuffer,
                                              indexBufferOffset: submesh.indexBufferOffset)
            }
            encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        }

        let transparentMeshes = mesh.subMeshes.filter { submesh in
            guard document.materialSettings.indices.contains(submesh.materialIndex) else { return false }
            let settings = document.materialSettings[submesh.materialIndex]
            return settings.visible && settings.diffuse.w < 0.999
        }.sorted { lhs, rhs in
            simd_distance(lhs.center, eye) > simd_distance(rhs.center, eye)
        }

        if !transparentMeshes.isEmpty {
            encoder.setRenderPipelineState(meshTransparentPipeline)
            encoder.setDepthStencilState(overlayDepthState)
            bindMeshBuffers(encoder, mesh: mesh)
            setScene(scene, encoder: encoder, vertexIndex: 6)
            if let paletteBuffer = updatePaletteBuffer(pose.palettes) {
                encoder.setVertexBuffer(paletteBuffer, offset: 0, index: 7)
            }
            encoder.setFragmentBytes(&scene, length: MemoryLayout<MMDSceneUniforms>.stride, index: 0)
            for submesh in transparentMeshes {
                let materialIndex = submesh.materialIndex
                let settings = document.materialSettings[materialIndex]
                let material = model.materials[materialIndex]
                let baseTexture = (settings.useTexture && material.textureIndex >= 0)
                    ? textures.embeddedOrFallback(index: material.textureIndex, model: model,
                                                  baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
                    : textures.whiteTexture
                let sphereTexture = (material.sphereIndex >= 0 && settings.sphereMode != 0)
                    ? textures.embeddedOrFallback(index: material.sphereIndex, model: model,
                                                  baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
                    : textures.whiteTexture
                let toonTexture = textures.toonTexture(for: material, model: model,
                                                       baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
                encoder.setFragmentTexture(baseTexture, index: 0)
                encoder.setFragmentTexture(sphereTexture, index: 1)
                encoder.setFragmentTexture(toonTexture, index: 2)
                var uniforms = makeMaterialUniforms(document: document, materialIndex: materialIndex,
                                                    transparent: true, flags: 0,
                                                    texturePresent: settings.useTexture && material.textureIndex >= 0,
                                                    spherePresent: material.sphereIndex >= 0 && settings.sphereMode != 0,
                                                    toonPresent: settings.useToon)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: 1)
                encoder.setCullMode(settings.doubleSided ? .none : .back)
                encoder.drawIndexedPrimitives(type: .triangle,
                                              indexCount: submesh.indexCount,
                                              indexType: .uint32,
                                              indexBuffer: mesh.indexBuffer,
                                              indexBufferOffset: submesh.indexBufferOffset)
            }
        }

        encodeAttachments(encoder, scene: scene, document: document,
                          characterSkeleton: skeleton, characterPose: pose)

        if lightSettings.photoIncludeBones, lightSettings.showBones {
            buildBoneOverlay(document: document, model: model, pose: pose)
            if let overlayBuffer, overlayCapacity > 0 {
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setDepthStencilState(overlayDepthState)
                encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 0)
                setScene(scene, encoder: encoder, vertexIndex: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: overlayCapacity)
            }
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        bytes.withUnsafeMutableBytes { raw in
            resolveTexture.getBytes(raw.baseAddress!,
                                    bytesPerRow: rowBytes,
                                    from: MTLRegionMake2D(0, 0, width, height),
                                    mipmapLevel: 0)
        }
        let data = Data(bytes)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            completion(nil)
            return
        }
        MMDLog.shared.info("Offscreen render: \(width)x\(height), transparent=\(transparent)",
                           category: "Render")
        completion(UIImage(cgImage: image, scale: 1, orientation: .up))
    }

    /// Starts a per-frame capture used by the engine recorder. The handler is
    /// called off the main thread with tightly packed BGRA rows.
    func setEngineCaptureHandler(_ handler: ((Data, Int, Int, Int) -> Void)?) {
        engineCaptureHandler = handler
        lastEngineCaptureTime = 0
    }

    /// One-finger scene editing used by the on-canvas transform gizmo.
    func transformSelection(deltaX: Float, deltaY: Float) {
        guard let document else { return }
        if abs(deltaX) + abs(deltaY) < 0.0001 { return }
        let height = max(160, Float(view?.bounds.height ?? 700))
        let worldPerPoint = 2 * camera.distance * tanf(mmdRadians(camera.fovDegrees) * 0.5) / height
        let right = SIMD3<Float>(cosf(camera.yaw), 0, -sinf(camera.yaw))
        let up = SIMD3<Float>(0, 1, 0)

        func translation() -> SIMD3<Float> {
            switch document.transformAxis {
            case .free: return right * deltaX * worldPerPoint + up * (-deltaY * worldPerPoint)
            case .x: return SIMD3<Float>(deltaX * worldPerPoint, 0, 0)
            case .y: return SIMD3<Float>(0, -deltaY * worldPerPoint, 0)
            case .z: return SIMD3<Float>(0, 0, deltaX * worldPerPoint)
            }
        }

        if let id = document.selectedAttachmentID {
            document.updateAttachment(id: id) { attachment in
                switch document.transformMode {
                case .translate:
                    attachment.position += translation()
                case .rotate:
                    switch document.transformAxis {
                    case .free:
                        attachment.rotation.y += deltaX * 0.45
                        attachment.rotation.x += deltaY * 0.45
                    case .x: attachment.rotation.x += deltaX * 0.45
                    case .y: attachment.rotation.y += deltaX * 0.45
                    case .z: attachment.rotation.z += deltaX * 0.45
                    }
                case .scale:
                    let factor = max(0.90, min(1.10, expf((deltaX - deltaY) * 0.006)))
                    switch document.transformAxis {
                    case .free: attachment.scale = simd_max(SIMD3<Float>(0.02, 0.02, 0.02), attachment.scale * factor)
                    case .x: attachment.scale.x = max(0.02, attachment.scale.x * factor)
                    case .y: attachment.scale.y = max(0.02, attachment.scale.y * factor)
                    case .z: attachment.scale.z = max(0.02, attachment.scale.z * factor)
                    }
                }
            }
            return
        }

        if let id = document.selectedLightID,
           let index = document.renderSettings.lights.firstIndex(where: { $0.id == id }) {
            let kind = document.renderSettings.lights[index].kind
            if document.transformMode == .translate, kind != .sun {
                document.renderSettings.lights[index].position += translation()
            } else {
                var direction = document.renderSettings.lights[index].direction
                if simd_length(direction) < 0.001 { direction = SIMD3<Float>(0, 1, 0) }
                let angle = mmdRadians(deltaX * 0.6)
                let axis: SIMD3<Float>
                switch document.transformAxis {
                case .x: axis = SIMD3<Float>(1, 0, 0)
                case .y: axis = SIMD3<Float>(0, 1, 0)
                case .z: axis = SIMD3<Float>(0, 0, 1)
                case .free: axis = simd_normalize(SIMD3<Float>(deltaY, deltaX, 0.2))
                }
                let rotated = simd_quatf(angle: angle, axis: axis).act(simd_normalize(direction))
                document.renderSettings.lights[index].direction = rotated
            }
            return
        }

        let bone = document.selectedBoneIndex
        guard document.model.bones.indices.contains(bone) else { return }
        if document.transformMode == .translate {
            let move = translation()
            document.boneOffsets[bone] = (document.boneOffsets[bone] ?? .zero) + move
        } else if document.transformMode == .rotate {
            let axisValue = deltaX * 0.45
            var value = document.boneRotations[bone] ?? .zero
            switch document.transformAxis {
            case .free:
                value.x += deltaY * 0.45
                value.y += axisValue
            case .x: value.x += axisValue
            case .y: value.y += axisValue
            case .z: value.z += axisValue
            }
            document.setBoneRotation(index: bone, degrees: value)
        }
    }

    // MARK: - Camera controls

    func resetCamera() {
        if let mesh { camera.fit(bounds: mesh.bounds) }
        document?.useCameraMotion = false
    }

    /// Camera presets used by the on-canvas camera panel. They always switch
    /// back to a manual camera so a VMD camera track cannot override the view.
    func applyCameraPreset(_ preset: String) {
        guard let mesh else { return }
        let radius = max(mesh.bounds.radius, 0.5)
        var next = camera
        switch preset {
        case "front":
            next.yaw = 0
            next.pitch = 0.1
            next.distance = max(radius * 4.2, 4)
            next.fovDegrees = 30
        case "back":
            next.yaw = .pi
            next.pitch = 0.1
            next.distance = max(radius * 4.2, 4)
            next.fovDegrees = 30
        case "left":
            next.yaw = -.pi / 2
            next.pitch = 0.1
            next.distance = max(radius * 4.2, 4)
            next.fovDegrees = 30
        case "right":
            next.yaw = .pi / 2
            next.pitch = 0.1
            next.distance = max(radius * 4.2, 4)
            next.fovDegrees = 30
        case "top":
            next.yaw = 0
            next.pitch = 1.2
            next.distance = max(radius * 4.6, 4)
            next.fovDegrees = 30
        case "close":
            next.distance = max(radius * 2.2, 2)
            next.fovDegrees = 28
        case "wide":
            next.distance = max(radius * 4.8, 4)
            next.fovDegrees = 48
        default:
            return
        }
        camera = next
        document?.useCameraMotion = false
    }

    func orbitCamera(deltaX: Float, deltaY: Float) {
        document?.useCameraMotion = false
        let width = Float(view?.bounds.width ?? 390)
        let height = Float(view?.bounds.height ?? 700)
        camera.orbit(deltaX: deltaX, deltaY: deltaY,
                     viewportWidth: width, viewportHeight: height)
    }

    func panCamera(deltaX: Float, deltaY: Float) {
        document?.useCameraMotion = false
        let width = Float(view?.bounds.width ?? 390)
        let height = Float(view?.bounds.height ?? 700)
        camera.pan(deltaX: deltaX, deltaY: deltaY,
                  viewportWidth: width, viewportHeight: height)
    }

    func zoomCamera(scale: Float) {
        document?.useCameraMotion = false
        camera.zoom(scale: scale)
    }

    func setCameraFOV(_ fov: Float) {
        document?.useCameraMotion = false
        camera.fovDegrees = max(12, min(90, fov))
    }

    func setCameraDistance(_ distance: Float) {
        document?.useCameraMotion = false
        camera.distance = max(0.5, min(200, distance))
    }

    func setAutoOrbit(_ enabled: Bool) {
        document?.useCameraMotion = false
        autoOrbitEnabled = enabled
        lastAutoOrbitTime = 0
    }

    // MARK: - Frame preparation

    private func refreshMorphPositions(document: MMDModelDocument, model: PMXModel,
                                       frame: Float, force: Bool = false) {
        guard let mesh, !basePositions.isEmpty,
              morphedPositions.count == basePositions.count else { return }
        let weights = document.effectiveMorphWeights(frame: frame)
        if !force, weights.count == lastMorphWeights.count {
            var same = true
            for index in weights.indices where abs(weights[index] - lastMorphWeights[index]) > 0.0005 {
                same = false
                break
            }
            if same { return }
        }
        guard !model.morphs.isEmpty else {
            if mesh.vertexCount == basePositions.count {
                mesh.updatePositions(basePositions)
            }
            lastMorphWeights = weights
            return
        }

        // Propagate group morphs exactly like MMDMorphController.resolvedWeights,
        // but into reusable buffers so an expression slider does not allocate a
        // new Float array per pass.
        if resolvedWeightsScratch.count != model.morphs.count {
            resolvedWeightsScratch = [Float](repeating: 0, count: model.morphs.count)
            groupAdditionsScratch = [Float](repeating: 0, count: model.morphs.count)
        }
        for index in resolvedWeightsScratch.indices {
            resolvedWeightsScratch[index] = index < weights.count ? weights[index] : 0
            groupAdditionsScratch[index] = 0
        }
        for _ in 0..<3 {
            var changed = false
            for (index, morph) in model.morphs.enumerated()
            where morph.isGroup && abs(resolvedWeightsScratch[index]) > 0.0001 {
                let base = resolvedWeightsScratch[index]
                for item in morph.groupItems {
                    guard item.morphIndex >= 0, item.morphIndex < groupAdditionsScratch.count else { continue }
                    groupAdditionsScratch[item.morphIndex] += base * item.ratio
                }
            }
            for index in resolvedWeightsScratch.indices where abs(groupAdditionsScratch[index]) > 0.00001 {
                resolvedWeightsScratch[index] += groupAdditionsScratch[index]
                groupAdditionsScratch[index] = 0
                changed = true
            }
            if !changed { break }
            for index in groupAdditionsScratch.indices where groupAdditionsScratch[index] != 0 {
                groupAdditionsScratch[index] = 0
            }
        }

        let count = morphedPositions.count
        morphedPositions.withUnsafeMutableBufferPointer { destination in
            basePositions.withUnsafeBufferPointer { source in
                if let dst = destination.baseAddress, let src = source.baseAddress {
                    dst.update(from: src, count: count)
                }
            }
        }
        for (morphIndex, morph) in model.morphs.enumerated() where morph.isVertex {
            guard morphIndex < resolvedWeightsScratch.count else { continue }
            let weight = resolvedWeightsScratch[morphIndex]
            guard abs(weight) > 0.00001 else { continue }
            for offset in morph.vertexOffsets {
                let vertexIndex = offset.vertexIndex
                guard vertexIndex >= 0, vertexIndex < count else { continue }
                morphedPositions[vertexIndex] += offset.offset * weight
            }
        }
        mesh.updatePositions(morphedPositions)
        lastMorphWeights = weights
    }

    private func makeMaterialUniforms(document: MMDModelDocument, materialIndex: Int,
                                      transparent: Bool, flags: UInt32,
                                      texturePresent: Bool, spherePresent: Bool,
                                      toonPresent: Bool) -> MMDMaterialUniforms {
        let material = document.model.materials[materialIndex]
        let settings = document.materialSettings.indices.contains(materialIndex)
            ? document.materialSettings[materialIndex]
            : MMDMaterialSettings(material: material, index: materialIndex)
        return makeMaterialUniforms(renderSettings: document.renderSettings,
                                    material: material, settings: settings,
                                    transparent: transparent, flags: flags,
                                    texturePresent: texturePresent, spherePresent: spherePresent,
                                    toonPresent: toonPresent)
    }

    private func makeMaterialUniforms(renderSettings: MMDRenderSettings,
                                      material: PMXMaterial, settings: MMDMaterialSettings,
                                      transparent: Bool, flags: UInt32,
                                      texturePresent: Bool, spherePresent: Bool,
                                      toonPresent: Bool) -> MMDMaterialUniforms {
        var uniforms = MMDMaterialUniforms()
        uniforms.diffuse = settings.diffuse
        uniforms.specular = SIMD4<Float>(material.specular.x * settings.diffuse.x,
                                        material.specular.y * settings.diffuse.y,
                                        material.specular.z * settings.diffuse.z,
                                        max(1, material.specularPower))
        uniforms.ambient = SIMD4<Float>(material.ambient.x, material.ambient.y, material.ambient.z * settings.diffuse.z, 1)
        uniforms.edgeColor = settings.edgeColor
        uniforms.sphereTint = SIMD4<Float>(1, 1, 1, 1)
        uniforms.edgeSize = max(0, settings.edgeSize) * renderSettings.edgeScale
        uniforms.alphaTest = transparent ? 0.0 : (texturePresent ? 0.35 : 0.03)
        uniforms.sphereMode = Int32(settings.sphereMode)
        let effectiveRenderMode: MMDRenderMode = renderSettings.toonEnabled
            ? renderSettings.renderMode : .realistic
        uniforms.renderMode = effectiveRenderMode.index

        var materialFlags: UInt32 = flags
        if texturePresent { materialFlags |= 1 }
        if spherePresent && settings.sphereMode != 0 { materialFlags |= 2 }
        if toonPresent && settings.useToon && effectiveRenderMode == .toon { materialFlags |= 4 }
        if settings.doubleSided { materialFlags |= 8 }
        if !transparent { materialFlags |= 16 }
        uniforms.flags = materialFlags
        return uniforms
    }

    private func bindMeshBuffers(_ encoder: MTLRenderCommandEncoder, mesh: MMDMesh) {
        encoder.setVertexBuffer(mesh.positionsBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(mesh.normalsBuffer, offset: 0, index: 1)
        encoder.setVertexBuffer(mesh.uvsBuffer, offset: 0, index: 2)
        encoder.setVertexBuffer(mesh.boneIndicesBuffer, offset: 0, index: 3)
        encoder.setVertexBuffer(mesh.weightsBuffer, offset: 0, index: 4)
        encoder.setVertexBuffer(mesh.edgeScalesBuffer, offset: 0, index: 5)
    }

    private func setScene(_ scene: MMDSceneUniforms, encoder: MTLRenderCommandEncoder, vertexIndex: Int) {
        var uniforms = scene
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MMDSceneUniforms>.stride, index: vertexIndex)
    }

    private func setMaterial(_ material: MMDMaterialUniforms, encoder: MTLRenderCommandEncoder, index: Int) {
        var uniforms = material
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: index)
    }

    /// Draw imported weapons/props as independent PMX meshes. A bound prop
    /// follows the selected character bone's rest-to-current delta while
    /// retaining its own editable world transform.
    @discardableResult
    private func encodeAttachments(_ encoder: MTLRenderCommandEncoder,
                                   scene baseScene: MMDSceneUniforms,
                                   document: MMDModelDocument,
                                   characterSkeleton: MMDSkeleton,
                                   characterPose: MMDSkeletonPose) -> (draws: Int, triangles: Int) {
        guard let textures, !document.attachments.isEmpty else { return (0, 0) }
        var draws = 0
        var triangles = 0

        for attachment in document.attachments where attachment.visible {
            guard let item = attachmentItems[attachment.id] else { continue }
            var modelMatrix = attachment.transformMatrix
            if let bone = attachment.boundBoneIndex,
               characterPose.worldMatrices.indices.contains(bone),
               characterSkeleton.restWorld.indices.contains(bone) {
                let delta = characterPose.worldMatrices[bone] * simd_inverse(characterSkeleton.restWorld[bone])
                modelMatrix = delta * modelMatrix
            }
            var scene = baseScene
            scene.model = modelMatrix
            scene.normalMatrix = simd_inverse(modelMatrix).transpose
            let centerBone = document.humanoidBindings[.center] ?? -1
            var driveRotation: simd_quatf?
            if centerBone >= 0,
               characterPose.worldMatrices.indices.contains(centerBone),
               characterSkeleton.restWorld.indices.contains(centerBone) {
                let delta = characterPose.worldMatrices[centerBone] * simd_inverse(characterSkeleton.restWorld[centerBone])
                driveRotation = quatFromRotationMatrix(simd_float3x3(
                    SIMD3<Float>(delta.columns.0.x, delta.columns.0.y, delta.columns.0.z),
                    SIMD3<Float>(delta.columns.1.x, delta.columns.1.y, delta.columns.1.z),
                    SIMD3<Float>(delta.columns.2.x, delta.columns.2.y, delta.columns.2.z)))
            }
            let attachmentAnimations = item.physics.apply(
                animations: [:], model: item.model,
                settings: document.physicsSettings,
                time: Double(document.currentFrame / max(1, document.frameRate)),
                driveRotation: driveRotation)
            let pose = item.skeleton.solve(animations: attachmentAnimations, model: item.model)
            let palettes = pose.palettes
            if item.paletteBuffer == nil || item.paletteCapacity < palettes.count {
                item.paletteCapacity = palettes.count
                item.paletteBuffer = device.makeBuffer(length: MemoryLayout<simd_float4x4>.stride * max(1, palettes.count),
                                                       options: .storageModeShared)
            }
            if let buffer = item.paletteBuffer, !palettes.isEmpty {
                let pointer = buffer.contents().bindMemory(to: simd_float4x4.self, capacity: palettes.count)
                for index in palettes.indices { pointer[index] = palettes[index] }
            }

            bindMeshBuffers(encoder, mesh: item.mesh)
            setScene(scene, encoder: encoder, vertexIndex: 6)
            var fragmentScene = scene
            encoder.setFragmentBytes(&fragmentScene, length: MemoryLayout<MMDSceneUniforms>.stride, index: 0)
            encoder.setFrontFacing(item.mesh.frontWinding)

            for transparentPass in [false, true] {
                encoder.setRenderPipelineState(transparentPass ? meshTransparentPipeline : meshOpaquePipeline)
                encoder.setDepthStencilState(transparentPass ? overlayDepthState : opaqueDepthState)
                if let palette = item.paletteBuffer {
                    encoder.setVertexBuffer(palette, offset: 0, index: 7)
                }
                for submesh in item.mesh.subMeshes {
                    let materialIndex = submesh.materialIndex
                    guard item.model.materials.indices.contains(materialIndex),
                          item.materialSettings.indices.contains(materialIndex) else { continue }
                    let material = item.model.materials[materialIndex]
                    let settings = item.materialSettings[materialIndex]
                    guard settings.visible, (settings.diffuse.w < 0.999) == transparentPass else { continue }
                    let hasTexture = settings.useTexture && material.textureIndex >= 0
                    let hasSphere = material.sphereIndex >= 0 && settings.sphereMode != 0
                    let baseTexture = hasTexture
                        ? textures.embeddedOrFallback(index: material.textureIndex, model: item.model,
                                                     baseDirectory: item.baseDirectory, fallbackRoot: item.fallbackRoot)
                        : textures.whiteTexture
                    let sphereTexture = hasSphere
                        ? textures.embeddedOrFallback(index: material.sphereIndex, model: item.model,
                                                     baseDirectory: item.baseDirectory, fallbackRoot: item.fallbackRoot)
                        : textures.whiteTexture
                    let toonTexture = textures.toonTexture(for: material, model: item.model,
                                                           baseDirectory: item.baseDirectory, fallbackRoot: item.fallbackRoot)
                    encoder.setFragmentTexture(baseTexture, index: 0)
                    encoder.setFragmentTexture(sphereTexture, index: 1)
                    encoder.setFragmentTexture(toonTexture, index: 2)
                    var uniforms = makeMaterialUniforms(renderSettings: document.renderSettings,
                                                        material: material, settings: settings,
                                                        transparent: transparentPass, flags: 0,
                                                        texturePresent: hasTexture, spherePresent: hasSphere,
                                                        toonPresent: settings.useToon)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: 1)
                    encoder.setCullMode(settings.doubleSided ? .none : .back)
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: submesh.indexCount,
                                                  indexType: .uint32, indexBuffer: item.mesh.indexBuffer,
                                                  indexBufferOffset: submesh.indexBufferOffset)
                    draws += 1
                    triangles += submesh.indexCount / 3
                }
            }

            if effectiveEdges {
                encoder.setRenderPipelineState(edgePipeline)
                encoder.setDepthStencilState(overlayDepthState)
                encoder.setDepthBias(0.0006, slopeScale: 1.2, clamp: 0)
                if let palette = item.paletteBuffer { encoder.setVertexBuffer(palette, offset: 0, index: 8) }
                encoder.setCullMode(.front)
                for submesh in item.mesh.subMeshes {
                    let materialIndex = submesh.materialIndex
                    guard item.model.materials.indices.contains(materialIndex),
                          item.materialSettings.indices.contains(materialIndex) else { continue }
                    let material = item.model.materials[materialIndex]
                    let settings = item.materialSettings[materialIndex]
                    guard settings.visible, settings.hasEdge, settings.edgeSize > 0,
                          settings.diffuse.w >= 0.999 else { continue }
                    var uniforms = makeMaterialUniforms(renderSettings: document.renderSettings,
                                                        material: material, settings: settings,
                                                        transparent: false, flags: 0,
                                                        texturePresent: false, spherePresent: false, toonPresent: false)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: 7)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: 0)
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: submesh.indexCount,
                                                  indexType: .uint32, indexBuffer: item.mesh.indexBuffer,
                                                  indexBufferOffset: submesh.indexBufferOffset)
                    draws += 1
                    triangles += submesh.indexCount / 3
                }
                encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
            }
        }
        return (draws, triangles)
    }

    // MARK: - Quality and performance

    private var autoScale: CGFloat = 1.0
    private var autoLevel = 0

    private var effectiveEdges: Bool {
        guard let document else { return false }
        let settings = document.renderSettings
        guard settings.edgesEnabled, settings.renderMode.usesEdges else { return false }
        if settings.qualityMode == .performance { return false }
        if settings.qualityMode == .auto { return autoLevel < 2 }
        return true
    }

    private var effectiveShadow: Bool {
        guard let document else { return false }
        let settings = document.renderSettings
        guard settings.showGroundShadow else { return false }
        if settings.qualityMode == .performance { return false }
        if settings.qualityMode == .auto { return autoLevel < 2 }
        return true
    }

    private func applyQualityIfNeeded() {
        guard let document else { return }
        let mode = document.renderSettings.qualityMode
        if appliedQuality == mode { return }
        appliedQuality = mode
        switch mode {
        case .auto:
            autoScale = 1.0
            autoLevel = 0
            renderScale = 1.0
            view?.preferredFramesPerSecond = max(60, UIScreen.main.maximumFramesPerSecond)
        case .high:
            renderScale = 1.0
            view?.preferredFramesPerSecond = max(60, UIScreen.main.maximumFramesPerSecond)
        case .balanced:
            renderScale = CGFloat(mode.baseScale)
            view?.preferredFramesPerSecond = 60
        case .performance:
            renderScale = CGFloat(mode.baseScale)
            view?.preferredFramesPerSecond = 60
        }
        onRenderScaleChange?(renderScale)
        lastAdaptiveChange = CACurrentMediaTime()
    }

    private func recordFrame(cpu: Double, gpu: Double, draws: Int, triangles: Int) {
        let now = CACurrentMediaTime()
        var snapshot: (fps: Double, cpu: Double, gpu: Double, draws: Int, tris: Int)?
        statsLock.lock()
        statsFrames += 1
        statsCPUSum += cpu
        statsGPUSum += gpu
        statsDrawSum += draws
        statsTriangleSum += triangles
        let elapsed = now - statsWindowStart
        if elapsed >= 0.5 {
            snapshot = (Double(statsFrames) / max(elapsed, 0.001),
                        statsCPUSum / Double(max(statsFrames, 1)),
                        statsGPUSum / Double(max(statsFrames, 1)),
                        statsDrawSum / max(statsFrames, 1),
                        statsTriangleSum / max(statsFrames, 1))
            statsFrames = 0
            statsCPUSum = 0
            statsGPUSum = 0
            statsDrawSum = 0
            statsTriangleSum = 0
            statsWindowStart = now
        }
        statsLock.unlock()

        guard let snapshot else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyPerformanceSnapshot(fps: snapshot.fps,
                                           cpu: snapshot.cpu,
                                           gpu: snapshot.gpu,
                                           draws: snapshot.draws,
                                           triangles: snapshot.tris)
        }
    }

    private func applyPerformanceSnapshot(fps: Double, cpu: Double, gpu: Double,
                                          draws: Int, triangles: Int) {
        guard let document else { return }
        var stats = document.renderStats
        stats.fps = fps
        stats.frameMilliseconds = 1000 / max(fps, 0.001)
        stats.cpuMilliseconds = cpu * 1000
        stats.gpuMilliseconds = gpu > 0 ? gpu * 1000 : cpu * 1000
        stats.drawCalls = draws
        stats.triangles = triangles
        stats.renderScale = Double(renderScale)
        stats.resolution = "\(Int((view?.drawableSize.width ?? 0).rounded()))×\(Int((view?.drawableSize.height ?? 0).rounded()))"
        stats.qualityLabel = document.renderSettings.qualityMode.rawValue
            + (document.renderSettings.qualityMode == .auto ? " · \(autoLevel == 0 ? "全质量" : (autoLevel == 1 ? "降采样" : "精简"))" : "")
        stats.missingTextures = textures?.missingCount ?? 0
        document.renderStats = stats
        let names = textures?.missingTextureNames ?? []
        if document.missingTextureNames != names { document.missingTextureNames = names }

        guard document.renderSettings.qualityMode == .auto else { return }
        guard photoRestoreScale == nil else { return }
        let now = CACurrentMediaTime()
        guard now - lastAdaptiveChange > 1.0 else { return }
        let target = Double(max(30, view?.preferredFramesPerSecond ?? 60))
        let budget = 1000 / target
        let frameMs = stats.frameMilliseconds
        let tooSlow = frameMs > budget * 1.18 || (gpu > 0 && gpu > budget * 0.95)
        if tooSlow {
            if renderScale > 0.68 {
                autoScale = max(0.65, renderScale - 0.1)
                renderScale = autoScale
                onRenderScaleChange?(renderScale)
            } else if autoLevel < 2 {
                autoLevel += 1
                if autoLevel == 2 {
                    autoScale = 0.7
                    renderScale = autoScale
                    onRenderScaleChange?(renderScale)
                }
            }
            lastAdaptiveChange = now
        } else if frameMs < budget * 0.72, renderScale < 1.0 {
            autoScale = min(1.0, renderScale + 0.05)
            renderScale = autoScale
            onRenderScaleChange?(renderScale)
            lastAdaptiveChange = now
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // MTKView recreates its render targets automatically.
    }

    func draw(in view: MTKView) {
        let cpuStart = CACurrentMediaTime()
        applyQualityIfNeeded()
        reloadIfNeeded()

        if let document {
            view.clearColor = MTLClearColor(red: Double(document.renderSettings.backgroundColor.x),
                                            green: Double(document.renderSettings.backgroundColor.y),
                                            blue: Double(document.renderSettings.backgroundColor.z),
                                            alpha: 1)
        }

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Always start from a cleared attachment. Relying on MTKView's default
        // descriptor left the previous pose visible on some devices, which
        // looked like every rendered frame was stacked on top of the last one.
        descriptor.colorAttachments[0].loadAction = .clear
        if let document {
            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(document.renderSettings.backgroundColor.x),
                green: Double(document.renderSettings.backgroundColor.y),
                blue: Double(document.renderSettings.backgroundColor.z),
                alpha: 1)
        }
        if let depth = descriptor.depthAttachment {
            depth.loadAction = .clear
            depth.clearDepth = 1.0
            depth.storeAction = .dontCare
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        var drawCalls = 0
        var triangles = 0

        guard let document, let mesh, let skeleton, let textures else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        let model = document.model
        // Rendering samples the sub-frame position while `currentFrame` keeps
        // publishing at 30 Hz; without this the 120 Hz canvas repeated each
        // pose four times in a row.
        let renderFrame = document.interpolatedFrame()

        refreshMorphPositions(document: document, model: model, frame: renderFrame)

        if autoOrbitEnabled {
            let now = CACurrentMediaTime()
            if lastAutoOrbitTime > 0 {
                let delta = min(0.05, max(0.0, now - lastAutoOrbitTime))
                camera.yaw += Float(delta) * 0.14
            }
            lastAutoOrbitTime = now
        } else {
            lastAutoOrbitTime = 0
        }

        let aspect = Float(max(1, view.drawableSize.width) / max(1, view.drawableSize.height))
        let bounds = mesh.bounds
        let eye: SIMD3<Float>
        let target: SIMD3<Float>
        let fovDegrees: Float

        if document.useCameraMotion, let motion = document.motion, !motion.cameraKeys.isEmpty,
           let pose = VMDMotion.evaluateCamera(keys: motion.cameraKeys, frame: renderFrame) {
            eye = pose.eye
            target = pose.target
            fovDegrees = pose.fovDegrees
        } else {
            eye = camera.eye
            target = camera.target
            fovDegrees = camera.fovDegrees
        }

        let radius = max(bounds.radius, 0.5)
        let near = max(0.02, min(camera.distance * 0.02, radius * 0.2))
        let far = max(radius * 8, camera.distance + radius * 6) + 50
        let viewMatrix = mmdLookAt(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
        let projection = mmdPerspective(fovYRadians: mmdRadians(fovDegrees), aspect: aspect, near: near, far: far)

        let animations = document.effectiveBoneAnimations(frame: renderFrame)
        let pose = skeleton.solve(animations: animations, model: model, ikEnabled: document.ikEnabled)
        currentPose = pose

        var scene = MMDSceneUniforms()
        scene.viewProjection = projection * viewMatrix
        scene.view = viewMatrix
        scene.model = matrix_identity_float4x4
        scene.normalMatrix = matrix_identity_float4x4
        let intensity = max(0.2, min(2, document.renderSettings.lightIntensity))
        let lightSettings = document.renderSettings
        let activeLights = Array(lightSettings.lights.filter(\.enabled).prefix(8))
        var lightUniforms = activeLights.map { $0.uniform }
        while lightUniforms.count < 8 { lightUniforms.append(.zero) }
        scene.lights = (lightUniforms[0], lightUniforms[1], lightUniforms[2], lightUniforms[3],
                        lightUniforms[4], lightUniforms[5], lightUniforms[6], lightUniforms[7])
        scene.lightCount = SIMD4<Float>(Float(activeLights.count),
                                        max(0.05, min(1.0, lightSettings.lightAmbient)),
                                        max(0.5, min(2.0, lightSettings.exposure)),
                                        max(2.0, min(5.0, lightSettings.style.toonSteps)))
        if let firstSun = lightSettings.lights.first(where: { $0.kind == .sun && $0.enabled }) {
            let direction = simd_length(firstSun.direction) > 0.0001
                ? simd_normalize(firstSun.direction)
                : SIMD3<Float>(0.4, 0.8, 0.5)
            scene.lightDirection = SIMD4<Float>(direction.x, direction.y, direction.z, 0)
            scene.lightColor = SIMD4<Float>(firstSun.color.x * firstSun.intensity,
                                            firstSun.color.y * firstSun.intensity,
                                            firstSun.color.z * firstSun.intensity, 1)
        } else {
            scene.lightDirection = SIMD4<Float>(0.4, 0.8, 0.5, 0)
            scene.lightColor = SIMD4<Float>(0.95 * intensity, 0.95 * intensity, 1.0 * intensity, 1)
        }
        scene.ambientColor = SIMD4<Float>(0.18, 0.18, 0.21,
                                          max(0.55, min(1.75, lightSettings.saturation)))
        scene.lightParams = SIMD4<Float>(max(0.05, min(1.0, lightSettings.lightAmbient)),
                                         max(0.0, min(1.0, lightSettings.lightFill)),
                                         max(0.0, min(1.0, lightSettings.lightRim)),
                                         max(0.5, min(2.0, lightSettings.exposure)))
        scene.cameraPosition = SIMD4<Float>(eye.x, eye.y, eye.z, 1)
        let groundY = bounds.minPoint.y
        let gridSpacing = max(0.05, bounds.height / 20)
        scene.params = SIMD4<Float>(groundY + 0.002, gridSpacing,
                                    document.renderSettings.edgeScale,
                                    lightSettings.style.index)
        scene.viewportSize = SIMD4<Float>(Float(max(1, view.drawableSize.width)),
                                          Float(max(1, view.drawableSize.height)), 0, 0)
        scene.gradeParams = SIMD4<Float>(max(0.70, min(1.60, lightSettings.contrast)),
                                         max(0.0, min(2.0, lightSettings.bloom)),
                                         max(0.0, min(1.4, lightSettings.vignette)),
                                         max(0.0, min(2.0, lightSettings.reflection)))
        scene.toonParams = SIMD4<Float>(max(0.0, min(0.45, lightSettings.toonSoftness)),
                                        max(0.0, min(1.0, lightSettings.toonShadowLift)),
                                        max(0.0, min(1.0, lightSettings.toonRim)), 0)
        scene.toonShadowTint = lightSettings.toonShadowTint
        scene.worldParams = SIMD4<Float>(max(0, lightSettings.worldScattering),
                                         max(0, lightSettings.worldIntensity), 0, 0)
        scene.worldSkyColor = lightSettings.worldSkyColor
        scene.worldGroundColor = lightSettings.worldGroundColor

        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(view.drawableSize.width),
                                        height: Double(view.drawableSize.height),
                                        znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setFrontFacing(mesh.frontWinding)
        encoder.setTriangleFillMode(.fill)

        // Studio backdrop: a full-screen gradient with a soft center glow.
        // Drawn first, depth-tested against the cleared depth buffer.
        drawBackdrop(encoder: encoder, settings: document.renderSettings,
                     aspect: Float(max(1, view.drawableSize.width) / max(1, view.drawableSize.height)),
                     document: document)
        drawCalls += 1
        encoder.setTriangleFillMode(document.renderSettings.renderMode == .wireframe ? .lines : .fill)

        // Grid
        if document.renderSettings.showGrid, let gridBuffer, gridVertexCount > 0 {
            encoder.setRenderPipelineState(gridPipeline)
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            setScene(scene, encoder: encoder, vertexIndex: 1)
            var sceneForFragment = scene
            encoder.setFragmentBytes(&sceneForFragment, length: MemoryLayout<MMDSceneUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gridVertexCount)
            drawCalls += 1
            triangles += gridVertexCount / 3
        }

        // Soft contact shadow. The previous pass projected every triangle
        // onto the floor and filled it with a flat 55% black silhouette, which
        // looked like a second flattened character. A radial contact patch
        // keeps the model grounded without producing that artifact.
        if effectiveShadow, let groundShadowBuffer, groundShadowVertexCount > 0 {
            encoder.setRenderPipelineState(contactShadowPipeline)
            encoder.setDepthStencilState(shadowDepthState)
            encoder.setVertexBuffer(groundShadowBuffer, offset: 0, index: 0)
            setScene(scene, encoder: encoder, vertexIndex: 1)
            encoder.setCullMode(.none)
            encoder.setTriangleFillMode(.fill)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: groundShadowVertexCount)
            encoder.setTriangleFillMode(document.renderSettings.renderMode == .wireframe ? .lines : .fill)
            drawCalls += 1
        }

        // Opaque pass
        encoder.setRenderPipelineState(meshOpaquePipeline)
        encoder.setDepthStencilState(opaqueDepthState)
        bindMeshBuffers(encoder, mesh: mesh)
        setScene(scene, encoder: encoder, vertexIndex: 6)
        if let paletteBuffer = updatePaletteBuffer(pose.palettes) {
            encoder.setVertexBuffer(paletteBuffer, offset: 0, index: 7)
        }
        encoder.setFragmentBytes(&scene, length: MemoryLayout<MMDSceneUniforms>.stride, index: 0)

        for submesh in mesh.subMeshes {
            let materialIndex = submesh.materialIndex
            guard document.materialSettings.indices.contains(materialIndex) else { continue }
            let settings = document.materialSettings[materialIndex]
            guard settings.visible, settings.diffuse.w >= 0.999 else { continue }
            let material = model.materials[materialIndex]

            let baseTexture = (settings.useTexture && material.textureIndex >= 0)
                ? textures.embeddedOrFallback(index: material.textureIndex, model: model, baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
                : textures.whiteTexture
            let sphereTexture = (material.sphereIndex >= 0 && settings.sphereMode != 0)
                ? textures.embeddedOrFallback(index: material.sphereIndex, model: model, baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
                : textures.whiteTexture
            let toonTexture = textures.toonTexture(for: material, model: model, baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
            encoder.setFragmentTexture(baseTexture, index: 0)
            encoder.setFragmentTexture(sphereTexture, index: 1)
            encoder.setFragmentTexture(toonTexture, index: 2)

            let uniforms = makeMaterialUniforms(document: document, materialIndex: materialIndex,
                                                transparent: false, flags: 0,
                                                texturePresent: settings.useTexture && material.textureIndex >= 0,
                                                spherePresent: material.sphereIndex >= 0 && settings.sphereMode != 0,
                                                toonPresent: settings.useToon)
            var materialUniforms = uniforms
            encoder.setFragmentBytes(&materialUniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: 1)
            encoder.setCullMode(settings.doubleSided ? .none : .back)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: submesh.indexCount,
                                          indexType: .uint32,
                                          indexBuffer: mesh.indexBuffer,
                                          indexBufferOffset: submesh.indexBufferOffset)
            drawCalls += 1
            triangles += submesh.indexCount / 3
        }

        // Edge pass
        if effectiveEdges {
            encoder.setRenderPipelineState(edgePipeline)
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setDepthBias(0.0006, slopeScale: 1.2, clamp: 0)
            bindMeshBuffers(encoder, mesh: mesh)
            setScene(scene, encoder: encoder, vertexIndex: 6)
            if let paletteBuffer = updatePaletteBuffer(pose.palettes) {
                encoder.setVertexBuffer(paletteBuffer, offset: 0, index: 8)
            }
            encoder.setCullMode(.front)
            for submesh in mesh.subMeshes {
                let materialIndex = submesh.materialIndex
                guard document.materialSettings.indices.contains(materialIndex) else { continue }
                let settings = document.materialSettings[materialIndex]
                let material = model.materials[materialIndex]
                guard settings.visible, settings.hasEdge, settings.edgeSize > 0,
                      settings.diffuse.w >= 0.999 else { continue }
                let uniforms = makeMaterialUniforms(document: document, materialIndex: materialIndex,
                                                    transparent: false, flags: 0,
                                                    texturePresent: false, spherePresent: false, toonPresent: false)
                var materialUniforms = uniforms
                encoder.setVertexBytes(&materialUniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: 7)
                encoder.setFragmentBytes(&materialUniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle,
                                              indexCount: submesh.indexCount,
                                              indexType: .uint32,
                                              indexBuffer: mesh.indexBuffer,
                                              indexBufferOffset: submesh.indexBufferOffset)
                drawCalls += 1
                triangles += submesh.indexCount / 3
            }
            encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        }

        // Transparent pass
        let transparentMeshes = mesh.subMeshes.filter { submesh in
            guard document.materialSettings.indices.contains(submesh.materialIndex) else { return false }
            let settings = document.materialSettings[submesh.materialIndex]
            return settings.visible && settings.diffuse.w < 0.999
        }.sorted { lhs, rhs in
            simd_distance(lhs.center, eye) > simd_distance(rhs.center, eye)
        }

        if !transparentMeshes.isEmpty {
            encoder.setRenderPipelineState(meshTransparentPipeline)
            encoder.setDepthStencilState(overlayDepthState)
            bindMeshBuffers(encoder, mesh: mesh)
            setScene(scene, encoder: encoder, vertexIndex: 6)
            if let paletteBuffer = updatePaletteBuffer(pose.palettes) {
                encoder.setVertexBuffer(paletteBuffer, offset: 0, index: 7)
            }
            encoder.setFragmentBytes(&scene, length: MemoryLayout<MMDSceneUniforms>.stride, index: 0)
            for submesh in transparentMeshes {
                let materialIndex = submesh.materialIndex
                let settings = document.materialSettings[materialIndex]
                let material = model.materials[materialIndex]
                let baseTexture = (settings.useTexture && material.textureIndex >= 0)
                    ? textures.embeddedOrFallback(index: material.textureIndex, model: model, baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
                    : textures.whiteTexture
                let sphereTexture = (material.sphereIndex >= 0 && settings.sphereMode != 0)
                    ? textures.embeddedOrFallback(index: material.sphereIndex, model: model, baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
                    : textures.whiteTexture
                let toonTexture = textures.toonTexture(for: material, model: model, baseDirectory: baseDirectory, fallbackRoot: fallbackRoot)
                encoder.setFragmentTexture(baseTexture, index: 0)
                encoder.setFragmentTexture(sphereTexture, index: 1)
                encoder.setFragmentTexture(toonTexture, index: 2)
                let uniforms = makeMaterialUniforms(document: document, materialIndex: materialIndex,
                                                    transparent: true, flags: 0,
                                                    texturePresent: settings.useTexture && material.textureIndex >= 0,
                                                    spherePresent: material.sphereIndex >= 0 && settings.sphereMode != 0,
                                                    toonPresent: settings.useToon)
                var materialUniforms = uniforms
                encoder.setFragmentBytes(&materialUniforms, length: MemoryLayout<MMDMaterialUniforms>.stride, index: 1)
                encoder.setCullMode(settings.doubleSided ? .none : .back)
                encoder.drawIndexedPrimitives(type: .triangle,
                                              indexCount: submesh.indexCount,
                                              indexType: .uint32,
                                              indexBuffer: mesh.indexBuffer,
                                              indexBufferOffset: submesh.indexBufferOffset)
                drawCalls += 1
                triangles += submesh.indexCount / 3
            }
        }

        let attachmentStats = encodeAttachments(encoder, scene: scene, document: document,
                                                characterSkeleton: skeleton, characterPose: pose)
        drawCalls += attachmentStats.draws
        triangles += attachmentStats.triangles

        // Bone and scene-transform overlays
        if document.renderSettings.showBones || document.sceneEditEnabled {
            buildBoneOverlay(document: document, model: model, pose: pose,
                             includeGizmo: document.sceneEditEnabled)
            if let overlayBuffer, overlayCapacity > 0 {
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setDepthStencilState(document.sceneEditEnabled ? gizmoDepthState : overlayDepthState)
                encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 0)
                setScene(scene, encoder: encoder, vertexIndex: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: overlayCapacity)
                drawCalls += 1
            }
        }

        // Metal allows only one encoder on a command buffer at a time. The
        // optional photo/video blits below must start after the render pass
        // has been closed; creating a blit encoder while the render encoder
        // is still open is invalid and can terminate the process.
        encoder.endEncoding()

        var photoBuffer: MTLBuffer?
        var photoWidth = 0
        var photoHeight = 0
        var photoRowBytes = 0
        if photoPending {
            let texture = drawable.texture
            photoWidth = texture.width
            photoHeight = texture.height
            photoRowBytes = ((photoWidth * 4 + 255) / 256) * 256
            if let buffer = device.makeBuffer(length: photoRowBytes * photoHeight,
                                              options: .storageModeShared),
               let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: photoWidth, height: photoHeight, depth: 1),
                          to: buffer, destinationOffset: 0,
                          destinationBytesPerRow: photoRowBytes,
                          destinationBytesPerImage: photoRowBytes * photoHeight)
                blit.endEncoding()
                photoBuffer = buffer
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.photoCompletion?(nil)
                    self?.photoCompletion = nil
                    self?.restorePhotoScale()
                }
            }
            photoPending = false
        }

        var videoBuffer: MTLBuffer?
        var videoWidth = 0
        var videoHeight = 0
        var videoRowBytes = 0
        var videoHandler: ((Data, Int, Int, Int) -> Void)?
        if let handler = engineCaptureHandler {
            let now = CACurrentMediaTime()
            if now - lastEngineCaptureTime >= engineCaptureInterval {
                lastEngineCaptureTime = now
                let texture = drawable.texture
                videoWidth = texture.width
                videoHeight = texture.height
                videoRowBytes = ((videoWidth * 4 + 255) / 256) * 256
                let length = videoRowBytes * videoHeight
                if let buffer = device.makeBuffer(length: length, options: .storageModeShared),
                   let blit = commandBuffer.makeBlitCommandEncoder() {
                    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: videoWidth, height: videoHeight, depth: 1),
                              to: buffer, destinationOffset: 0,
                              destinationBytesPerRow: videoRowBytes,
                              destinationBytesPerImage: length)
                    blit.endEncoding()
                    videoBuffer = buffer
                    videoHandler = handler
                } else {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .mmdStopEngineCapture, object: nil)
                    }
                }
            }
        }

        lastDrawCalls = drawCalls
        lastTriangles = triangles
        let cpuElapsed = CACurrentMediaTime() - cpuStart
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let gpuElapsed = max(0, buffer.gpuEndTime - buffer.gpuStartTime)
            self?.recordFrame(cpu: cpuElapsed, gpu: gpuElapsed,
                              draws: drawCalls, triangles: triangles)
            guard let self else { return }
            if let photoBuffer {
                let image = Self.image(from: photoBuffer,
                                       width: photoWidth, height: photoHeight,
                                       bytesPerRow: photoRowBytes)
                DispatchQueue.main.async {
                    self.photoCompletion?(image)
                    self.photoCompletion = nil
                    self.restorePhotoScale()
                }
            }
            if let videoBuffer, let videoHandler, videoWidth > 0, videoHeight > 0 {
                let data = Data(bytes: videoBuffer.contents(), count: videoRowBytes * videoHeight)
                DispatchQueue.global(qos: .userInitiated).async {
                    videoHandler(data, videoWidth, videoHeight, videoRowBytes)
                }
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Helpers

    private static func image(from buffer: MTLBuffer, width: Int, height: Int,
                              bytesPerRow: Int) -> UIImage? {
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }
        let length = bytesPerRow * height
        guard length > 0, buffer.length >= length else { return nil }
        let data = Data(bytes: buffer.contents(), count: length)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: bytesPerRow, space: colorSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                    provider: provider, decode: nil,
                                    shouldInterpolate: true, intent: .defaultIntent) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up)
    }

    private func makeBackdrop(document: MMDModelDocument) -> MMDStudioBackdropUniforms {
        let background = document.renderSettings.backgroundColor
        let style = document.renderSettings.style
        var glow = SIMD3<Float>(0.30, 0.46, 0.62)
        switch style {
        case .mmd: glow = SIMD3<Float>(0.30, 0.46, 0.62)
        case .genshin: glow = SIMD3<Float>(0.58, 0.42, 0.30)
        case .starRail: glow = SIMD3<Float>(0.26, 0.36, 0.66)
        case .zenless: glow = SIMD3<Float>(0.62, 0.34, 0.22)
        }
        let top = SIMD4<Float>(min(1, background.x * 1.25 + 0.035),
                               min(1, background.y * 1.22 + 0.040),
                               min(1, background.z * 1.18 + 0.050), 1)
        let bottom = SIMD4<Float>(background.x * 0.42,
                                  background.y * 0.40,
                                  background.z * 0.44, 1)
        return MMDStudioBackdropUniforms(topColor: top,
                                         bottomColor: bottom,
                                         glowColor: SIMD4<Float>(glow.x, glow.y, glow.z, 1),
                                         params: SIMD4<Float>(0.60, 0.42, 0, 0))
    }

    private func rebuildGroundOverlays(bounds: MMDBox) {
        rebuildGrid(bounds: bounds)
        rebuildContactShadow(bounds: bounds)
    }

    private func rebuildContactShadow(bounds: MMDBox) {
        let groundY = bounds.minPoint.y + 0.004
        let radius = max(bounds.radius * 1.08, 3)
        let center = SIMD3<Float>(bounds.center.x, groundY, bounds.center.z)
        let corners: [(SIMD3<Float>, SIMD2<Float>)] = [
            (SIMD3<Float>(center.x - radius, groundY, center.z - radius), SIMD2<Float>(0, 0)),
            (SIMD3<Float>(center.x + radius, groundY, center.z - radius), SIMD2<Float>(1, 0)),
            (SIMD3<Float>(center.x + radius, groundY, center.z + radius), SIMD2<Float>(1, 1)),
            (SIMD3<Float>(center.x - radius, groundY, center.z - radius), SIMD2<Float>(0, 0)),
            (SIMD3<Float>(center.x + radius, groundY, center.z + radius), SIMD2<Float>(1, 1)),
            (SIMD3<Float>(center.x - radius, groundY, center.z + radius), SIMD2<Float>(0, 1))
        ]
        let vertices = corners.map { pair in
            MMDDrawVertex(position: pair.0, color: SIMD4<Float>(pair.1.x, pair.1.y, 0, 1))
        }
        groundShadowVertexCount = vertices.count
        groundShadowBuffer = device.makeBuffer(bytes: vertices,
                                               length: MemoryLayout<MMDDrawVertex>.stride * vertices.count,
                                               options: .storageModeShared)
    }

    private func rebuildGrid(bounds: MMDBox) {
        let groundY = bounds.minPoint.y
        let extent = max(bounds.radius * 40, 60)
        let corners: [SIMD3<Float>] = [
            SIMD3<Float>(-extent, groundY, -extent),
            SIMD3<Float>(extent, groundY, -extent),
            SIMD3<Float>(extent, groundY, extent),
            SIMD3<Float>(-extent, groundY, -extent),
            SIMD3<Float>(extent, groundY, extent),
            SIMD3<Float>(-extent, groundY, extent)
        ]
        let vertices = corners.map { MMDDrawVertex(position: $0, color: SIMD4<Float>(1, 1, 1, 1)) }
        gridVertexCount = vertices.count
        gridBuffer = device.makeBuffer(bytes: vertices,
                                       length: MemoryLayout<MMDDrawVertex>.stride * vertices.count,
                                       options: .storageModeShared)
    }

    private func ensureOverlayCapacity(_ count: Int) -> MTLBuffer? {
        if let overlayBuffer, overlayAllocated >= count { return overlayBuffer }
        let capacity = max(count, 256)
        overlayAllocated = capacity
        let buffer = device.makeBuffer(length: MemoryLayout<MMDDrawVertex>.stride * capacity,
                                       options: .storageModeShared)
        overlayBuffer = buffer
        overlayCapacity = capacity
        return buffer
    }

    private func updatePaletteBuffer(_ palettes: [simd_float4x4]) -> MTLBuffer? {
        guard !palettes.isEmpty else { return nil }
        if paletteBuffer == nil || paletteCapacity < palettes.count {
            paletteCapacity = palettes.count
            paletteBuffer = device.makeBuffer(length: MemoryLayout<simd_float4x4>.stride * palettes.count,
                                              options: .storageModeShared)
        }
        guard let paletteBuffer else { return nil }
        let pointer = paletteBuffer.contents().bindMemory(to: simd_float4x4.self, capacity: palettes.count)
        for index in palettes.indices { pointer[index] = palettes[index] }
        return paletteBuffer
    }

    private func buildBoneOverlay(document: MMDModelDocument, model: PMXModel, pose: MMDSkeletonPose,
                                  includeGizmo: Bool = false) {
        var vertices = [MMDDrawVertex]()
        vertices.reserveCapacity(model.bones.count * 2 + 160)

        let normalColor = SIMD4<Float>(0.25, 0.85, 1.0, 0.62)
        let selectedColor = SIMD4<Float>(1.0, 0.62, 0.18, 1.0)
        let highlightColor = SIMD4<Float>(1.0, 0.85, 0.3, 0.9)

        if document.renderSettings.showBones,
           !model.bones.isEmpty, pose.worldMatrices.count == model.bones.count {
            for (index, bone) in model.bones.enumerated() {
                let position = pose.worldMatrices[index].translation
                if bone.parentIndex >= 0 && bone.parentIndex < model.bones.count {
                    let parent = pose.worldMatrices[bone.parentIndex].translation
                    let color = index == document.selectedBoneIndex ? selectedColor : normalColor
                    vertices.append(MMDDrawVertex(position: position, color: color))
                    vertices.append(MMDDrawVertex(position: parent, color: color))
                }
                if bone.tailIndex >= 0 && bone.tailIndex < model.bones.count {
                    let tail = pose.worldMatrices[bone.tailIndex].translation
                    vertices.append(MMDDrawVertex(position: position, color: normalColor))
                    vertices.append(MMDDrawVertex(position: tail, color: normalColor))
                }
            }

            if document.selectedBoneIndex >= 0 && document.selectedBoneIndex < model.bones.count {
                let center = pose.worldMatrices[document.selectedBoneIndex].translation
                let size = max(model.bounds.height * 0.015, 0.02)
                let axes: [SIMD3<Float>] = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
                for axis in axes {
                    vertices.append(MMDDrawVertex(position: center - axis * size, color: selectedColor))
                    vertices.append(MMDDrawVertex(position: center + axis * size, color: selectedColor))
                }
                if let ik = model.bones[document.selectedBoneIndex].ik,
                   ik.targetIndex >= 0 && ik.targetIndex < model.bones.count {
                    let target = pose.worldMatrices[ik.targetIndex].translation
                    vertices.append(MMDDrawVertex(position: center, color: highlightColor))
                    vertices.append(MMDDrawVertex(position: target, color: highlightColor))
                }
            }
        }

        if includeGizmo, let center = editorSelectionCenter(document: document, pose: pose) {
            let size = max(model.bounds.height * 0.13, 0.25)
            let axes: [SIMD3<Float>] = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
            let colors = [SIMD4<Float>(1, 0.18, 0.18, 1), SIMD4<Float>(0.45, 1, 0.25, 1), SIMD4<Float>(0.18, 0.55, 1, 1)]
            for axisIndex in 0..<3 {
                let axis = axes[axisIndex]
                let end = center + axis * size
                let color = colors[axisIndex]
                if document.transformMode == .rotate {
                    let otherA = axes[(axisIndex + 1) % 3]
                    let otherB = axes[(axisIndex + 2) % 3]
                    let segments = 28
                    for segment in 0..<segments {
                        let a = Float(segment) / Float(segments) * 2 * Float.pi
                        let b = Float(segment + 1) / Float(segments) * 2 * Float.pi
                        let ca = cosf(a) * size
                        let sa = sinf(a) * size
                        let cb = cosf(b) * size
                        let sb = sinf(b) * size
                        let p0 = center + otherA * ca + otherB * sa
                        let p1 = center + otherA * cb + otherB * sb
                        vertices.append(MMDDrawVertex(position: p0, color: color))
                        vertices.append(MMDDrawVertex(position: p1, color: color))
                    }
                } else {
                    vertices.append(MMDDrawVertex(position: center, color: color))
                    vertices.append(MMDDrawVertex(position: end, color: color))
                    let other = axes[(axisIndex + 1) % 3]
                    let headSize = size * 0.12
                    vertices.append(MMDDrawVertex(position: end, color: color))
                    vertices.append(MMDDrawVertex(position: end - axis * headSize + other * headSize * 0.55, color: color))
                    vertices.append(MMDDrawVertex(position: end, color: color))
                    vertices.append(MMDDrawVertex(position: end - axis * headSize - other * headSize * 0.55, color: color))
                    if document.transformMode == .scale {
                        let thirdAxis = axes[(axisIndex + 2) % 3]
                        let offsetA = other * (size * 0.055)
                        let offsetB = thirdAxis * (size * 0.055)
                        let c0 = end - offsetA - offsetB
                        let c1 = end + offsetA - offsetB
                        let c2 = end + offsetA + offsetB
                        let c3 = end - offsetA + offsetB
                        let corners = [c0, c1, c2, c3]
                        for corner in 0..<4 {
                            vertices.append(MMDDrawVertex(position: corners[corner], color: color))
                            vertices.append(MMDDrawVertex(position: corners[(corner + 1) % 4], color: color))
                        }
                    }
                }
            }
        }

        guard !vertices.isEmpty, let buffer = ensureOverlayCapacity(vertices.count) else {
            overlayCapacity = 0
            return
        }
        let raw = buffer.contents().bindMemory(to: MMDDrawVertex.self, capacity: vertices.count)
        for index in vertices.indices { raw[index] = vertices[index] }
        overlayCapacity = vertices.count
    }

    private func editorSelectionCenter(document: MMDModelDocument, pose: MMDSkeletonPose) -> SIMD3<Float>? {
        if let id = document.selectedAttachmentID,
           let attachment = document.attachments.first(where: { $0.id == id }) {
            var matrix = attachment.transformMatrix
            if let bone = attachment.boundBoneIndex,
               let skeleton, skeleton.restWorld.indices.contains(bone), pose.worldMatrices.indices.contains(bone) {
                matrix = pose.worldMatrices[bone] * simd_inverse(skeleton.restWorld[bone]) * matrix
            }
            return matrix.translation
        }
        if let id = document.selectedLightID,
           let light = document.renderSettings.lights.first(where: { $0.id == id }) {
            if light.kind == .sun {
                let direction = simd_length(light.direction) > 0.001 ? simd_normalize(light.direction) : SIMD3<Float>(0, 1, 0)
                return camera.target + direction * max(document.model.bounds.height * 0.55, 2)
            }
            return light.position
        }
        if document.model.bones.indices.contains(document.selectedBoneIndex),
           pose.worldMatrices.indices.contains(document.selectedBoneIndex) {
            return pose.worldMatrices[document.selectedBoneIndex].translation
        }
        return nil
    }
}
