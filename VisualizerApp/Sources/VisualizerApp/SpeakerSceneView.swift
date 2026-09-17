import SwiftUI
import SceneKit

enum CameraPreset: String, CaseIterable, Identifiable {
    case top = "Top", front = "Front", side = "Side", perspective = "Perspective"
    var id: Self { self }
}

enum LabelMode: String, CaseIterable, Identifiable {
    case number = "Ch", numberAndName = "Ch + Name"
    var id: Self { self }
}

/// SSD speakers in SceneKit. Nodes are built once per scene load; a 30 Hz timer
/// then only touches materials, scale and line visibility (no per-frame rebuild).
/// Speakers have no drawn orientation: SSD defines no SPEAKER front axis.
struct SpeakerSceneView: NSViewRepresentable {
    @ObservedObject var sceneModel: SSDSceneModel
    let audio: AudioLevelsModel      // read by the timer, deliberately not observed
    let levelOverride: [Float]?      // --docshot synthetic levels
    @Binding var selectedChannel: Int?
    let camera: CameraPreset
    let showLines: Bool
    let labelMode: LabelMode

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = ResizeAwareSCNView()
        let c = context.coordinator
        view.scene = SCNScene()
        view.scene?.rootNode.addChildNode(c.content)
        view.backgroundColor = NSColor(white: 0.07, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = true
        c.cameraNode.camera = SCNCamera()
        view.scene?.rootNode.addChildNode(c.cameraNode)
        view.pointOfView = c.cameraNode
        view.addGestureRecognizer(NSClickGestureRecognizer(target: c, action: #selector(Coordinator.clicked(_:))))
        view.onResize = { [weak c] in c?.frameCamera() }
        c.view = view
        c.startTimer()
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        c.props = self
        if c.generation != sceneModel.generation {
            c.rebuild(sceneModel.speakers)
            c.generation = sceneModel.generation
        }
        if c.labelMode != labelMode { c.apply(labelMode) }
        if c.camera != camera { c.apply(camera) }
        if c.selected != selectedChannel { c.select(selectedChannel) }
        c.tick()
    }

    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
    }

    final class ResizeAwareSCNView: SCNView {
        var onResize: (() -> Void)?
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            onResize?()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        struct SpeakerNodes {
            let speaker: Speaker
            let ball: SCNNode
            let material: SCNMaterial
            let label: SCNNode
            let ring: SCNNode
            let line: SCNNode
        }

        static let pickMask = 2
        var props: SpeakerSceneView?
        weak var view: SCNView?
        let content = SCNNode()
        let cameraNode = SCNNode()
        var timer: Timer?
        var nodes: [SpeakerNodes] = []
        var lastDb: [Float] = []
        var generation = -1
        var labelMode: LabelMode?
        var camera: CameraPreset?
        var selected: Int? = -1           // -1 = not applied yet (channels are >= 1)
        var lo = SIMD3<Double>(-1, -1, 0), hi = SIMD3<Double>(1, 1, 1)

        func startTimer() {
            let t = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        // MARK: build (once per scene load)

        func rebuild(_ speakers: [Speaker]) {
            content.childNodes.forEach { $0.removeFromParentNode() }
            nodes = []
            lo = .zero; hi = .zero                      // bounds include the listener at the origin
            for s in speakers { lo = pointwiseMin(lo, s.position); hi = pointwiseMax(hi, s.position) }
            // Widen x/y to whole meters + 1 so the floor grid (and the axes at its corner) are framed too.
            lo = [floor(lo.x) - 1, floor(lo.y) - 1, lo.z]
            hi = [ceil(hi.x) + 1, ceil(hi.y) + 1, hi.z]

            content.addChildNode(grid())
            content.addChildNode(axes(at: [lo.x, lo.y, 0]))  // grid corner, clear of speakers
            content.addChildNode(listener())
            for (i, s) in speakers.enumerated() { nodes.append(speakerNodes(s, index: i)) }
            lastDb = Array(repeating: .nan, count: nodes.count)
            labelMode = nil; camera = nil; selected = -1   // re-apply to the new nodes
        }

        private func speakerNodes(_ s: Speaker, index: Int) -> SpeakerNodes {
            let holder = SCNNode()
            holder.position = scenekit(s.position)
            if !s.active { holder.opacity = 0.3 }      // Enabled=0 (or disabled parent): ghost
            content.addChildNode(holder)

            let material = SCNMaterial()
            material.lightingModel = .blinn
            let ball = SCNNode(geometry: SCNSphere(radius: 0.16))
            ball.geometry?.firstMaterial = material
            ball.name = String(index)
            ball.categoryBitMask = Self.pickMask
            holder.addChildNode(ball)

            let facing = SCNNode()                       // everything 2D faces the camera
            facing.constraints = [SCNBillboardConstraint()]
            holder.addChildNode(facing)

            let label = textNode("", height: 0.24, color: .white)
            label.position = SCNVector3(0, 0.44, 0)          // above the ring and a fully scaled ball
            label.name = String(index)
            label.categoryBitMask = Self.pickMask
            facing.addChildNode(label)

            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.36, pipeRadius: 0.03))
            ring.geometry?.firstMaterial = flat(.systemCyan)
            ring.eulerAngles.x = .pi / 2                 // torus axis -> facing +Z (towards camera)
            ring.isHidden = true
            facing.addChildNode(ring)

            if s.mute {
                for angle in [CGFloat.pi / 4, -CGFloat.pi / 4] {
                    let bar = SCNNode(geometry: SCNBox(width: 0.5, height: 0.06, length: 0.001, chamferRadius: 0))
                    let m = flat(.systemRed)
                    m.readsFromDepthBuffer = false
                    bar.geometry?.firstMaterial = m
                    bar.renderingOrder = 10
                    bar.eulerAngles.z = angle
                    facing.addChildNode(bar)
                }
            }

            let line = lines([(.zero, s.position)], color: .white)
            line.isHidden = true
            content.addChildNode(line)
            return SpeakerNodes(speaker: s, ball: ball, material: material, label: label, ring: ring, line: line)
        }

        private func grid() -> SCNNode {
            let x0 = lo.x, x1 = hi.x, y0 = lo.y, y1 = hi.y
            var segments: [(SIMD3<Double>, SIMD3<Double>)] = []
            for x in stride(from: x0, through: x1, by: 1) { segments.append(([x, y0, 0], [x, y1, 0])) }
            for y in stride(from: y0, through: y1, by: 1) { segments.append(([x0, y, 0], [x1, y, 0])) }
            return lines(segments, color: NSColor(white: 1, alpha: 0.13))
        }

        private func axes(at origin: SIMD3<Double>) -> SCNNode {
            let node = SCNNode()
            let axes: [(SIMD3<Double>, NSColor, String)] = [
                ([1, 0, 0], .systemRed, "+X 右"), ([0, 1, 0], .systemGreen, "+Y 前方"), ([0, 0, 1], .systemBlue, "+Z 上"),
            ]
            for (direction, color, title) in axes {
                node.addChildNode(lines([(origin, origin + direction)], color: color))
                let anchor = SCNNode()
                anchor.position = scenekit(origin + direction * 1.3)
                anchor.constraints = [SCNBillboardConstraint()]
                anchor.addChildNode(textNode(title, height: 0.2, color: color))
                node.addChildNode(anchor)
            }
            return node
        }

        private func listener() -> SCNNode {
            let node = SCNNode()
            let disc = SCNNode(geometry: SCNCylinder(radius: 0.3, height: 0.005))
            disc.geometry?.firstMaterial = flat(NSColor(white: 1, alpha: 0.25))
            node.addChildNode(disc)
            // The listener faces SSD +Y (front) by definition of the axes; speakers get no arrow.
            let arrow = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.1, height: 0.3))
            arrow.geometry?.firstMaterial = flat(NSColor(white: 0.9, alpha: 1))
            arrow.position = scenekit([0, 0.15, 0.02])
            arrow.eulerAngles.x = -.pi / 2               // cone tip (+Y) -> SceneKit -Z = SSD +Y
            node.addChildNode(arrow)
            let anchor = SCNNode()
            anchor.position = scenekit([0, -0.3, 0])
            anchor.constraints = [SCNBillboardConstraint()]
            let label = textNode("listener", height: 0.14, color: NSColor(white: 0.7, alpha: 1))
            label.position = SCNVector3(0, -0.2, 0)
            anchor.addChildNode(label)
            node.addChildNode(anchor)
            return node
        }

        // MARK: updates

        func apply(_ mode: LabelMode) {
            labelMode = mode
            for n in nodes {
                let s = n.speaker
                setText(n.label, mode == .number || s.name.isEmpty ? "\(s.channel)" : "\(s.channel) \(s.name)")
            }
        }

        func select(_ channel: Int?) {
            selected = channel
            for n in nodes { n.ring.isHidden = n.speaker.channel != channel }
        }

        @objc func tick() {
            guard let props else { return }
            let levels = props.levelOverride ?? props.audio.levels
            for (i, n) in nodes.enumerated() {
                let db = channelDb(levels, n.speaker.channel)
                let lineOn = props.showLines && db > LevelThreshold.line
                if abs(db - lastDb[i]) < 0.25 && n.line.isHidden == !lineOn { continue }
                lastDb[i] = db

                let amount = levelAmount(db)
                let color = levelColor(db)
                let dim: CGFloat = n.speaker.mute ? 0.35 : 1
                n.material.diffuse.contents = scaled(color, 0.75 * dim)
                n.material.emission.contents = scaled(color, amount * dim)
                let s = 1 + 0.8 * amount
                n.ball.scale = SCNVector3(s, s, s)
                n.line.isHidden = !lineOn
                if lineOn { n.line.geometry?.firstMaterial?.diffuse.contents = color }
            }
        }

        // MARK: camera

        func apply(_ preset: CameraPreset) {
            camera = preset
            guard let view, let cam = cameraNode.camera else { return }
            let center = (lo + hi) / 2
            let size = hi - lo
            let radius = max(simd_length(size) / 2, 1)
            let eye: SIMD3<Double>, up: SIMD3<Double>
            switch preset {
            case .top: eye = center + [0, 0, radius * 4]; up = [0, 1, 0]          // screen up = SSD +Y (front)
            case .front: eye = center + [0, -radius * 4, 0]; up = [0, 0, 1]       // from behind, looking to +Y
            case .side: eye = center + [radius * 4, 0, 0]; up = [0, 0, 1]         // from +X, front to the right
            case .perspective: eye = center + simd_normalize(SIMD3(-0.55, -1, 0.7)) * radius * 2.6; up = [0, 0, 1]
            }
            cam.zNear = 0.05
            cam.zFar = radius * 20
            cam.fieldOfView = 40
            cam.usesOrthographicProjection = preset != .perspective
            cameraNode.position = scenekit(eye)
            cameraNode.look(at: scenekit(center), up: scenekit(up), localFront: SCNVector3(0, 0, -1))
            view.pointOfView = cameraNode
            view.allowsCameraControl = preset == .perspective
            if preset == .perspective {
                view.defaultCameraController.interactionMode = .orbitTurntable
                view.defaultCameraController.target = scenekit(center)
                view.defaultCameraController.worldUp = scenekit(up)
            }
            frameCamera()
        }

        /// Keeps the presets framed for the current view aspect. Runs on resize too;
        /// never moves the perspective camera (the user may have orbited it).
        func frameCamera() {
            guard let camera, let view, let cam = cameraNode.camera else { return }
            let aspect = view.bounds.height > 0 ? Double(view.bounds.width / view.bounds.height) : 1
            if camera == .perspective {
                cam.projectionDirection = aspect < 1 ? .horizontal : .vertical  // FOV on the narrow axis
                return
            }
            let size = hi - lo
            let (w, h) = camera == .top ? (size.x, size.y) : camera == .front ? (size.x, size.z) : (size.y, size.z)
            cam.orthographicScale = max(h, w / aspect) / 2 + 0.7  // margin for labels above the top row
        }

        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let view else { return }
            let hits = view.hitTest(gesture.location(in: view), options: [
                .categoryBitMask: Self.pickMask,
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
            ])
            if let name = hits.first?.node.name, let i = Int(name), nodes.indices.contains(i) {
                props?.selectedChannel = nodes[i].speaker.channel
            } else {
                props?.selectedChannel = nil
            }
        }
    }
}

// MARK: - SceneKit helpers

private func flat(_ color: NSColor) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = color
    return m
}

private func scaled(_ color: NSColor, _ k: CGFloat) -> NSColor {
    NSColor(srgbRed: color.redComponent * k, green: color.greenComponent * k, blue: color.blueComponent * k, alpha: 1)
}

/// Line segments given in SSD coordinates, one draw call.
private func lines(_ segments: [(SIMD3<Double>, SIMD3<Double>)], color: NSColor) -> SCNNode {
    var vertices: [SCNVector3] = []
    var indices: [Int32] = []
    for (a, b) in segments {
        indices += [Int32(vertices.count), Int32(vertices.count + 1)]
        vertices += [scenekit(a), scenekit(b)]
    }
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                               elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
    geometry.firstMaterial = flat(color)
    return SCNNode(geometry: geometry)
}

/// Flat text `height` meters tall, horizontally centred on its node, baseline at y = 0.
private func textNode(_ string: String, height: CGFloat, color: NSColor) -> SCNNode {
    let text = SCNText(string: string, extrusionDepth: 0)
    text.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    text.flatness = 0.2
    text.firstMaterial = flat(color)
    let node = SCNNode(geometry: text)
    let k = height / 12
    node.scale = SCNVector3(k, k, k)
    setText(node, string)
    return node
}

private func setText(_ node: SCNNode, _ string: String) {
    guard let text = node.geometry as? SCNText else { return }
    text.string = string
    let (min, max) = text.boundingBox
    node.pivot = SCNMatrix4MakeTranslation((min.x + max.x) / 2, 0, 0)
}
