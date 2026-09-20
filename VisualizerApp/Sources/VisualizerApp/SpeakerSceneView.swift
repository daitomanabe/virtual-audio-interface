import SwiftUI
import SceneKit

enum CameraPreset: String, CaseIterable, Identifiable {
    case top = "Top", front = "Front", side = "Side", perspective = "Perspective"
    var id: Self { self }
}

enum LabelMode: String, CaseIterable, Identifiable {
    case number = "Channel", numberAndName = "Channel + name"
    var id: Self { self }
}

/// SSD speakers and the scene's other objects in SceneKit. Nodes are built once per scene load;
/// a 30 Hz timer then only touches speaker materials, scale and line visibility (no per-frame rebuild).
/// Speakers have no drawn orientation: SSD defines no SPEAKER front axis.
struct SpeakerSceneView: NSViewRepresentable {
    @ObservedObject var sceneModel: SSDSceneModel
    let audio: AudioLevelsModel      // read by the timer, deliberately not observed
    let levelOverride: [Float]?      // --docshot synthetic levels
    @Binding var selectedChannel: Int?
    let camera: CameraPreset
    let showLines: Bool
    let labelMode: LabelMode
    let showObjects: Bool            // screens, LEDs, projectors, cameras, boxes, FOVs, other markers
    let applyGain: Bool              // light speakers by input + SSD Gain instead of the input level

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = ResizeAwareSCNView()
        let c = context.coordinator
        view.scene = SCNScene()
        view.scene?.rootNode.addChildNode(c.content)
        view.scene?.rootNode.addChildNode(c.objectRoot)
        view.backgroundColor = Theme.canvas
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
            // Re-frame only for Open / Reload; a save in an editor keeps the camera where it is.
            c.rebuild(sceneModel.speakers, sceneModel.objects, reframe: c.framing != sceneModel.framing)
            c.generation = sceneModel.generation
            c.framing = sceneModel.framing
        }
        c.objectRoot.isHidden = !showObjects
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
        let objectRoot = SCNNode()        // non-speaker objects; hidden by the "Scene objects" toggle
        let cameraNode = SCNNode()
        var timer: Timer?
        var nodes: [SpeakerNodes] = []
        var objectLabels: [SCNNode] = []
        var axisNodes: [(axis: SCNNode, label: SCNNode)] = []  // X, Y, Z
        var lastDb: [Float] = []
        var generation = -1
        var framing = -1
        var labelMode: LabelMode?
        var camera: CameraPreset?
        var selected: Int? = -1           // -1 = not applied yet (channels are >= 1)
        var lo = SIMD3<Double>(-1, -1, 0), hi = SIMD3<Double>(1, 1, 1)  // current scene (grid)
        var frameLo = SIMD3<Double>(-1, -1, 0), frameHi = SIMD3<Double>(1, 1, 1) // what the camera framed
        /// Scale of balls, labels, listener and axes: 1 for a 12 m floor grid, so they keep roughly the
        /// same size on screen in a small room and in a hall.
        var glyph: CGFloat = 1

        func startTimer() {
            let t = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        // MARK: build (once per scene load)

        func rebuild(_ speakers: [Speaker], _ objects: [SceneObject], reframe: Bool) {
            content.childNodes.forEach { $0.removeFromParentNode() }
            objectRoot.childNodes.forEach { $0.removeFromParentNode() }
            nodes = []
            objectLabels = []
            let others = objects.filter { $0.type != "speaker" }
            lo = [-3, -3, 0]; hi = [3, 3, 0]            // the listener's surroundings, even for an empty scene
            for p in speakers.map(\.position) + others.flatMap(extent) {
                lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p)
            }
            // Widen x/y to whole meters + 1 so the floor grid (and the axes at its corner) are framed too.
            lo = [floor(lo.x) - 1, floor(lo.y) - 1, lo.z]
            hi = [ceil(hi.x) + 1, ceil(hi.y) + 1, hi.z]
            glyph = CGFloat(min(max(max(hi.x - lo.x, hi.y - lo.y) / 12, 0.6), 4))

            content.addChildNode(grid())
            content.addChildNode(axes(at: [lo.x, lo.y, 0]))  // grid corner, clear of speakers
            content.addChildNode(listener())
            for (i, s) in speakers.enumerated() { nodes.append(speakerNodes(s, index: i)) }
            let parents = Set(objects.compactMap(\.parent))
            for o in others { addObject(o, all: objects, parents: parents) }
            lastDb = Array(repeating: .nan, count: nodes.count)
            labelMode = nil; selected = -1                 // re-apply to the new nodes
            if reframe { camera = nil }                    // updateNSView re-applies the preset to the new bounds
        }

        /// World points an object's drawing spans (for framing): origin, rectangle / box corners, FOV far plane.
        private func extent(_ o: SceneObject) -> [SIMD3<Double>] {
            var local: [SIMD3<Double>] = [.zero]
            if let r = o.rect { local += rectCorners(r) }
            if let b = o.box { local += boxCorners(b) }
            if let f = o.fov { local += frustumCorners(f.x, f.y, f.z) }
            return local.map(o.world)
        }

        /// Draws one non-speaker object in its own SceneKit frame (B·M·B⁻¹ from the bridge);
        /// geometry is given in SSD-local coordinates and mapped through `scenekit` like everything else.
        private func addObject(_ o: SceneObject, all: [SceneObject], parents: Set<Int>) {
            let holder = SCNNode()
            holder.simdTransform = o.sceneKitTransform
            if !o.active { holder.opacity = 0.3 }      // Enabled=0 (or disabled parent): ghost
            objectRoot.addChildNode(holder)
            var drawn = false
            if let r = o.rect {
                let color = o.type == "led" ? Theme.objectLED : Theme.objectSurface
                let corners = rectCorners(r)
                holder.addChildNode(face(corners, color: color.withAlphaComponent(0.12)))
                // Outline plus a short tick along +Z so the front side is visible.
                var segments = zip(corners, corners.dropFirst() + corners.prefix(1)).map { ($0, $1) }
                segments.append((.zero, [0, 0, min(0.4, 0.15 * min(r.x, r.y))]))
                holder.addChildNode(lines(segments, color: color.withAlphaComponent(0.7)))
                if let px = o.pixels {                  // coarse grid, at most 16 cells across
                    let cols = min(px.x, 16), rows = min(px.y, max(1, Int((Double(cols) * r.y / r.x).rounded())))
                    var grid: [(SIMD3<Double>, SIMD3<Double>)] = []
                    for i in 1..<cols { let x = r.x * (Double(i) / Double(cols) - 0.5); grid.append(([x, -r.y / 2, 0], [x, r.y / 2, 0])) }
                    for j in 1..<rows { let y = r.y * (Double(j) / Double(rows) - 0.5); grid.append(([-r.x / 2, y, 0], [r.x / 2, y, 0])) }
                    holder.addChildNode(lines(grid, color: color.withAlphaComponent(0.3)))
                }
                drawn = true
            }
            if let b = o.box {
                let c = boxCorners(b)                   // index bits: x, y, z
                let edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
                holder.addChildNode(lines(edges.map { (c[$0.0], c[$0.1]) }, color: Theme.objectBox))
                drawn = true
            }
            if let f = o.fov {
                holder.addChildNode(lines(pyramid(frustumCorners(f.x, f.y, f.z)), color: Theme.objectDevice.withAlphaComponent(0.4)))
                drawn = true
            }
            if o.type == "camera" || o.type == "projector" {
                // Small viewing pyramid along local +Z (see README: the axis the format's reference
                // viewer draws) with a tick marking the local +Y edge.
                let angles = o.cameraFov ?? o.fov.map { SIMD2($0.x, $0.y) } ?? SIMD2(50, 35)
                let base = frustumCorners(angles.x, angles.y, 0.35)
                let top = base[2].y, tick: [(SIMD3<Double>, SIMD3<Double>)] = [
                    ([-0.06, top, 0.35], [0, top + 0.07, 0.35]), ([0, top + 0.07, 0.35], [0.06, top, 0.35])]
                holder.addChildNode(lines(pyramid(base) + tick, color: Theme.objectDevice))
                drawn = true
            }
            if !drawn {                                // microphone, truss, sensor, ...: a small marker
                let marker = SCNNode(geometry: SCNSphere(radius: 0.07))
                marker.geometry?.firstMaterial = flat(Theme.objectMarker)
                holder.addChildNode(marker)
            }
            if let t = o.target, all.indices.contains(t) {  // projector -> target: dotted line
                let a = o.position, b = all[t].position, length = simd_distance(a, b)
                let dashes = stride(from: 0.0, to: length, by: 0.2).map { d in
                    (a + (b - a) * (d / length), a + (b - a) * (min(d + 0.1, length) / length))
                }
                let line = lines(dashes, color: Theme.objectDevice.withAlphaComponent(0.6))
                if !o.active { line.opacity = 0.3 }
                objectRoot.addChildNode(line)
            }

            // Name under the object (rectangles: under their bottom edge), shown in Ch + Name mode only.
            // A bare marker that only groups other objects (a rig or truss) stays unlabeled.
            if !drawn && parents.contains(o.id) { return }
            let anchor = SCNNode()
            anchor.position = scenekit(o.world(o.rect.map { [0, -$0.y / 2, 0] } ?? .zero))
            anchor.constraints = [SCNBillboardConstraint()]
            let label = textNode(o.name.isEmpty ? o.objectID : o.name, height: Theme.sceneLabelSmall * glyph,
                                 color: Theme.canvasTextDim)
            label.position = SCNVector3(0, -0.55 * glyph, 0)  // clear of a camera glyph pointing down-screen
            anchor.addChildNode(label)
            if !o.active { anchor.opacity = 0.3 }
            objectRoot.addChildNode(anchor)
            objectLabels.append(anchor)
        }

        private func speakerNodes(_ s: Speaker, index: Int) -> SpeakerNodes {
            let holder = SCNNode()
            holder.position = scenekit(s.position)
            holder.scale = SCNVector3(glyph, glyph, glyph)
            if s.silent { holder.opacity = 0.45 }      // Mute or Enabled 0 (or a disabled parent): ghost
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

            let label = textNode("", height: Theme.sceneLabel, color: Theme.canvasText)
            label.position = SCNVector3(0, 0.44, 0)          // above the ring and a fully scaled ball
            label.name = String(index)
            label.categoryBitMask = Self.pickMask
            facing.addChildNode(label)

            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.36, pipeRadius: 0.03))
            ring.geometry?.firstMaterial = flat(Theme.selection)
            ring.eulerAngles.x = .pi / 2                 // torus axis -> facing +Z (towards camera)
            ring.isHidden = true
            facing.addChildNode(ring)

            if s.mute {
                for angle in [CGFloat.pi / 4, -CGFloat.pi / 4] {
                    let bar = SCNNode(geometry: SCNBox(width: 0.5, height: 0.06, length: 0.001, chamferRadius: 0))
                    let m = flat(Theme.inactive)
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
            return lines(segments, color: Theme.canvasLine)
        }

        /// 1 m (× glyph) gizmo with its labels beside the tips (see `showAxes`).
        private func axes(at origin: SIMD3<Double>) -> SCNNode {
            let node = SCNNode()
            node.position = scenekit(origin)
            node.scale = SCNVector3(glyph, glyph, glyph)
            axisNodes = []
            let axes: [(SIMD3<Double>, NSColor, String)] = [
                ([1, 0, 0], Theme.axisX, "+X right"), ([0, 1, 0], Theme.axisY, "+Y front"), ([0, 0, 1], Theme.axisZ, "+Z up"),
            ]
            for (direction, color, title) in axes {
                let axis = SCNNode()
                axis.addChildNode(lines([(.zero, direction)], color: color))
                let anchor = SCNNode()
                anchor.position = scenekit(direction)
                anchor.constraints = [SCNBillboardConstraint()]
                let label = textNode(title, height: Theme.sceneLabelSmall, color: color)
                anchor.addChildNode(label)
                axis.addChildNode(anchor)
                node.addChildNode(axis)
                axisNodes.append((axis, label))
            }
            showAxes()
            return node
        }

        /// Hides the axis that points at the camera in an orthographic preset (its label would sit on the
        /// origin). Labels go to the right of their tips, except Y in perspective: seen from the front left,
        /// +Y projects just left of +Z, so its label goes left and the two do not collide.
        private func showAxes() {
            let hidden: Int? = camera == .side ? 0 : camera == .front ? 1 : camera == .top ? 2 : nil
            for (i, (axis, label)) in axisNodes.enumerated() {
                axis.isHidden = i == hidden
                guard let text = label.geometry else { continue }
                let (min, max) = text.boundingBox, right = !(i == 1 && camera == .perspective)
                label.pivot = SCNMatrix4MakeTranslation(right ? min.x : max.x, (min.y + max.y) / 2, 0)
                label.position = SCNVector3(right ? 0.1 : -0.1, 0, 0)
            }
        }

        private func listener() -> SCNNode {
            let node = SCNNode()
            node.scale = SCNVector3(glyph, glyph, glyph)
            let disc = SCNNode(geometry: SCNCylinder(radius: 0.3, height: 0.005))
            disc.geometry?.firstMaterial = flat(Theme.canvasText.withAlphaComponent(0.25))
            node.addChildNode(disc)
            // The listener faces SSD +Y (front) by definition of the axes; speakers get no arrow.
            let arrow = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.1, height: 0.3))
            arrow.geometry?.firstMaterial = flat(Theme.canvasText)
            arrow.position = scenekit([0, 0.15, 0.02])
            arrow.eulerAngles.x = -.pi / 2               // cone tip (+Y) -> SceneKit -Z = SSD +Y
            node.addChildNode(arrow)
            let anchor = SCNNode()
            anchor.position = scenekit([0, -0.3, 0])
            anchor.constraints = [SCNBillboardConstraint()]
            let label = textNode("listener", height: Theme.sceneLabelSmall, color: Theme.canvasTextDim)
            label.position = SCNVector3(0, -0.2, 0)
            anchor.addChildNode(label)
            node.addChildNode(anchor)
            return node
        }

        // MARK: updates

        func apply(_ mode: LabelMode) {
            labelMode = mode
            // A dense layout cannot fit names beside every speaker. The routing table still exposes
            // the full names, while the scene stays spatially legible with channel labels.
            let compactSpeakers = nodes.count > 16
            for n in nodes {
                setText(n.label, mode == .number || compactSpeakers ? "\(n.speaker.channel)" : n.speaker.longLabel)
            }
            // Dense review scenes remain useful with their geometry visible, but their object names
            // become unreadable and collide in orthographic views. Keep labels for small scenes and
            // suppress only the secondary object labels once the scene is clearly dense.
            let denseObjects = objectLabels.count > 24
            for label in objectLabels { label.isHidden = mode == .number || denseObjects || compactSpeakers }
        }

        func select(_ channel: Int?) {
            selected = channel
            for n in nodes { n.ring.isHidden = n.speaker.channel != channel }
        }

        @objc func tick() {
            guard let props else { return }
            let levels = props.levelOverride ?? props.audio.levels
            for (i, n) in nodes.enumerated() {
                let db = n.speaker.db(levels, applyGain: props.applyGain)
                let lineOn = props.showLines && !n.speaker.silent && db > LevelThreshold.line
                if abs(db - lastDb[i]) < 0.25 && n.line.isHidden == !lineOn { continue }
                lastDb[i] = db

                let color = levelColor(db)
                if n.speaker.silent {
                    // Muted or disabled: never lit or grown, whatever arrives on the channel. Signal that
                    // arrives anyway tints it with the warning color, like its routing warning.
                    let signal = channelDb(levels, n.speaker.channel) > LevelThreshold.signal
                    n.material.diffuse.contents = signal ? Theme.warning : Theme.inactive
                    n.material.emission.contents = NSColor.black
                    n.ball.scale = SCNVector3(1, 1, 1)
                } else {
                    let amount = levelAmount(db)
                    n.material.diffuse.contents = scaled(color, 0.75)
                    n.material.emission.contents = scaled(color, amount)
                    let s = 1 + 0.8 * amount
                    n.ball.scale = SCNVector3(s, s, s)
                }
                n.line.isHidden = !lineOn
                if lineOn { n.line.geometry?.firstMaterial?.diffuse.contents = color }
            }
        }

        // MARK: camera

        func apply(_ preset: CameraPreset) {
            camera = preset
            showAxes()
            guard let view, let cam = cameraNode.camera else { return }
            frameLo = lo; frameHi = hi
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
        /// never moves the perspective camera (the user may have orbited it). Uses the bounds the
        /// preset was applied with, so a reload after an edit does not zoom on the next resize.
        func frameCamera() {
            guard let camera, let view, let cam = cameraNode.camera else { return }
            let aspect = view.bounds.height > 0 ? Double(view.bounds.width / view.bounds.height) : 1
            if camera == .perspective {
                cam.projectionDirection = aspect < 1 ? .horizontal : .vertical  // FOV on the narrow axis
                return
            }
            let size = frameHi - frameLo
            let (w, h) = camera == .top ? (size.x, size.y) : camera == .front ? (size.x, size.z) : (size.y, size.z)
            cam.orthographicScale = max(h, w / aspect) / 2 + 0.7 * glyph  // margin for labels above the top row
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

/// The parse error over the 3D view (the last valid scene stays on screen while a half-saved edit
/// fails); the top bar shows the short form on every tab.
struct SceneLoadStatus: View {
    @ObservedObject var sceneModel: SSDSceneModel

    var body: some View {
        if let error = sceneModel.loadError {
            Label(sceneModel.showsLastValidScene ? "Parse error, showing the last valid version: \(error)"
                                                 : "Could not load: \(error)",
                  systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Fonts.body)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
                .background(Color(nsColor: Theme.error).opacity(0.9), in: RoundedRectangle(cornerRadius: Theme.radius))
                .padding(Theme.Space.s)
                .allowsHitTesting(false)      // clicks go to the speakers underneath
        }
    }
}

extension Speaker {
    /// Muted or disabled (Enabled 0 on it or an ancestor): it cannot sound, so it is never lit.
    var silent: Bool { mute || !active }

    /// Ch + Name label: "9 U1" and, when non-zero, Gain / Delay on a second line ("−1.5 dB · 1.2 ms").
    /// Parenthesized source IDs are useful in the file but too noisy for a spatial label.
    var longLabel: String {
        var extras: [String] = []
        if gainDb != 0 { extras.append(String(format: "%+.1f dB", gainDb).replacingOccurrences(of: "-", with: "−")) }
        if delayMs != 0 { extras.append(String(format: "%.1f ms", delayMs)) }
        let displayName = name.split { $0 == "(" || $0 == "/" || $0.isWhitespace }
            .first.map(String.init) ?? name
        let base = displayName.isEmpty ? "\(channel)" : "\(channel) \(displayName)"
        return extras.isEmpty ? base : base + "\n" + extras.joined(separator: " · ") // two short lines overlap less
    }
}

// MARK: - SSD-local shapes (meters)

/// Rectangle centered on the origin in the local XY plane: bottom-left, bottom-right, top-right, top-left.
private func rectCorners(_ size: SIMD2<Double>, z: Double = 0) -> [SIMD3<Double>] {
    let x = size.x / 2, y = size.y / 2
    return [[-x, -y, z], [x, -y, z], [x, y, z], [-x, y, z]]
}

/// Box centered on the origin; bit 0/1/2 of the index selects +x/+y/+z.
private func boxCorners(_ size: SIMD3<Double>) -> [SIMD3<Double>] {
    (0..<8).map { i in size / 2 * SIMD3(i & 1 == 0 ? -1 : 1, i & 2 == 0 ? -1 : 1, i & 4 == 0 ? -1 : 1) }
}

/// Far rectangle of a view looking along local +Z (X right), `distance` away. +Z matches the format's
/// reference viewer, which draws its FOV quad at local (±w, ±h, +distance).
private func frustumCorners(_ horizontalDeg: Double, _ verticalDeg: Double, _ distance: Double) -> [SIMD3<Double>] {
    let half = { (deg: Double) in distance * tan(deg / 2 * .pi / 180) }
    return rectCorners([2 * half(horizontalDeg), 2 * half(verticalDeg)], z: distance)
}

/// Edges from the origin to each corner plus the corner loop.
private func pyramid(_ corners: [SIMD3<Double>]) -> [(SIMD3<Double>, SIMD3<Double>)] {
    corners.map { (.zero, $0) } + zip(corners, corners.dropFirst() + corners.prefix(1)).map { ($0, $1) }
}

// MARK: - SceneKit helpers

/// Translucent double-sided quad (corners in SSD coordinates) that never hides what is behind it.
private func face(_ corners: [SIMD3<Double>], color: NSColor) -> SCNNode {
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: corners.map(scenekit))],
                               elements: [SCNGeometryElement(indices: [Int32(0), 1, 2, 0, 2, 3], primitiveType: .triangles)])
    let m = flat(color)
    m.isDoubleSided = true
    m.writesToDepthBuffer = false
    geometry.firstMaterial = m
    return SCNNode(geometry: geometry)
}

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

/// Flat text `height` meters tall per line, horizontally centred on its node, bottom at y = 0.
private func textNode(_ string: String, height: CGFloat, color: NSColor) -> SCNNode {
    let text = SCNText(string: string, extrusionDepth: 0)
    text.font = Theme.sceneFont
    text.flatness = 0.2
    text.firstMaterial = flat(color)
    let node = SCNNode(geometry: text)
    let k = height / Theme.sceneFont.pointSize
    node.scale = SCNVector3(k, k, k)
    setText(node, string)
    return node
}

private func setText(_ node: SCNNode, _ string: String) {
    guard let text = node.geometry as? SCNText else { return }
    text.string = string
    let (min, max) = text.boundingBox
    node.pivot = SCNMatrix4MakeTranslation((min.x + max.x) / 2, min.y, 0) // extra lines grow upwards
}
