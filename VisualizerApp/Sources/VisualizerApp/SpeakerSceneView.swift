import SwiftUI
import SceneKit

/// Renders SSD SPEAKER positions as spheres; each speaker's emission/scale
/// reacts to its channel's live meter level. One node per speaker, rebuilt
/// whenever the speaker list changes; updated in place every tick.
struct SpeakerSceneView: NSViewRepresentable {
    @ObservedObject var sceneModel: SSDSceneModel
    @ObservedObject var levels: AudioLevelsModel

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.allowsCameraControl = true
        view.backgroundColor = .black
        view.autoenablesDefaultLighting = true

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(0, 3, 8)
        view.scene?.rootNode.addChildNode(camera)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard let root = view.scene?.rootNode else { return }
        // Rebuild speaker nodes whenever a new .sscene was loaded (even if it
        // has the same speaker count as the previous one) or the count changed.
        if context.coordinator.lastGeneration != sceneModel.generation ||
            context.coordinator.lastSpeakerCount != sceneModel.speakers.count {
            root.childNodes.filter { $0.name == "speaker" }.forEach { $0.removeFromParentNode() }
            for speaker in sceneModel.speakers {
                let sphere = SCNSphere(radius: 0.15)
                sphere.firstMaterial?.diffuse.contents = NSColor.systemBlue
                let node = SCNNode(geometry: sphere)
                node.name = "speaker"
                node.position = SCNVector3(speaker.x, speaker.y, speaker.z)
                node.geometry?.firstMaterial?.emission.contents = NSColor.black
                node.setValue(speaker.channel, forKey: "channel")
                root.addChildNode(node)
            }
            context.coordinator.lastSpeakerCount = sceneModel.speakers.count
            context.coordinator.lastGeneration = sceneModel.generation
        }
        // Per-frame level highlight.
        for node in root.childNodes where node.name == "speaker" {
            guard let channel = node.value(forKey: "channel") as? Int32,
                  channel >= 1, Int(channel) <= levels.levels.count else { continue }
            let level = CGFloat(levels.levels[Int(channel) - 1])
            node.geometry?.firstMaterial?.emission.contents = NSColor.systemBlue.withAlphaComponent(level)
            let scale = Float(1.0 + level)
            node.scale = SCNVector3(scale, scale, scale)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastSpeakerCount: Int = -1; var lastGeneration: Int = -1 }
}
