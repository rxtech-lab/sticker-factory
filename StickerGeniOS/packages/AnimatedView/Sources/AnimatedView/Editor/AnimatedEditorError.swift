import Foundation

/// Why an edit was refused.
///
/// Every editing operation is total: it either returns a new, valid document or throws one of
/// these and leaves the caller's document untouched. There is deliberately no half-applied state,
/// which is what lets the undo stack record a snapshot only on success.
///
/// `layerIsDeclarative` is the Swift twin of the server's `assertNotDeclarative` in
/// `lib/contracts/sticker.ts`. Both exist for the same reason: a layer whose motion is owned by
/// declarative specs stores its keyframes as *derived* data, and hand-editing them would produce a
/// document that no longer equals its own recompilation — exactly what the document schema rejects.
/// Raising it here rather than at save time means the editor can offer the detach flow at the
/// moment of the gesture, while the user still knows what they were trying to do.
public enum AnimatedEditorError: Error, Equatable, LocalizedError {
    case layerNotFound(String)
    case layerIsDeclarative(String)
    case layerLimitReached
    case keyframeLimitReached(AnimationChannel)
    case documentKeyframeLimitReached
    case duplicateKeyframeTime(AnimationChannel, Double)
    case keyframeIndexOutOfRange(AnimationChannel, Int)
    case channelUnsupported(AnimationChannel, AnimatedLayerType)
    case wrongLayerType(String, AnimatedLayerType)
    case invalidAssetID(String)
    case invalidSVGMarkup
    case durationTooShortForAnimations(minimum: Double)
    case staticDocumentCannotAnimate
    case compile(String)

    public var errorDescription: String? {
        switch self {
        case .layerNotFound(let id):
            "There is no layer with the id \(id)."
        case .layerIsDeclarative(let id):
            "Layer \(id) uses preset motion, so its keyframes are generated. Convert it to keyframes to edit them directly."
        case .layerLimitReached:
            "A sticker can hold at most \(AnimatedDocument.maximumLayerCount) layers."
        case .keyframeLimitReached(let channel):
            "The \(channel.rawValue) track is full at \(AnimatedLayerAnimation.maximumKeyframesPerChannel) keyframes."
        case .documentKeyframeLimitReached:
            "This sticker has reached its budget of \(AnimatedDocument.maximumKeyframeCount) keyframes."
        case .duplicateKeyframeTime(let channel, let time):
            "The \(channel.rawValue) track already has a keyframe at \(String(format: "%.2f", time)) s."
        case .keyframeIndexOutOfRange(let channel, let index):
            "The \(channel.rawValue) track has no keyframe at position \(index)."
        case .channelUnsupported(let channel, let type):
            "A \(type.rawValue) layer has nothing for the \(channel.rawValue) track to affect."
        case .wrongLayerType(let id, let expected):
            "Layer \(id) is not a \(expected.rawValue) layer."
        case .invalidAssetID(let id):
            "\(id) is not a valid asset identifier."
        case .invalidSVGMarkup:
            "That SVG cannot be used: it is empty, too large, or references a script or a remote URL."
        case .durationTooShortForAnimations(let minimum):
            "The duration must be at least \(String(format: "%.2f", minimum)) s to fit this sticker's preset motion."
        case .staticDocumentCannotAnimate:
            "A static sticker has no timeline, so it cannot hold keyframes."
        case .compile(let message):
            message
        }
    }
}
