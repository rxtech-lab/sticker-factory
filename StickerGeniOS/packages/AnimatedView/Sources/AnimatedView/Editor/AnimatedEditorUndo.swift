import Foundation

/// Undo as a stack of whole-document snapshots.
///
/// Deliberately not `UndoManager`, for three reasons:
///
///  1. `@Environment(\.undoManager)` is non-`nil` only in a document-based host. A package view
///     embedded in an arbitrary screen would silently have no undo at all, which is a worse failure
///     than not offering it.
///  2. `UndoManager` registers *inverse closures*. With a value-type document the inverse is simply
///     the previous value, so all of that machinery buys nothing.
///  3. Coalescing a sixty-event drag into one undo step is a `coalescingKey` here, versus
///     `beginUndoGrouping`/`endUndoGrouping` plumbed through every gesture callback there.
///
/// Snapshots are affordable because `AnimatedDocument` is a struct of copy-on-write types: changing
/// one layer copies a twelve-element array of enums whose `String` payloads — including inline SVG
/// markup up to 200 KB — share storage with the original.
public struct AnimatedEditorUndoStack: Sendable {
    /// Enough history to undo one's way out of any real editing session, and a hard bound on the
    /// worst case if some future change ever makes a snapshot expensive to hold.
    public static let limit = 50

    private struct Entry: Sendable {
        var document: AnimatedDocument
        var name: String
        /// Non-`nil` while a gesture is in flight. Two consecutive entries sharing a key collapse
        /// into the first, so a drag is one undo step rather than sixty.
        var coalescingKey: String?
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoActionName: String? { undoStack.last?.name }
    public var redoActionName: String? { redoStack.first?.name }

    /// Records the document *as it was before* an edit that has already succeeded.
    ///
    /// Recording the prior state rather than the new one is what makes undo a pop: the current
    /// document always lives in the editor, never on the stack.
    public mutating func record(_ previous: AnimatedDocument, name: String, coalescingKey: String? = nil) {
        // A new edit invalidates any redo history — the timeline has forked.
        redoStack.removeAll()

        if let coalescingKey, undoStack.last?.coalescingKey == coalescingKey {
            // Already holding the state from before this gesture began; every later frame of the
            // same drag is redundant.
            return
        }
        undoStack.append(Entry(document: previous, name: name, coalescingKey: coalescingKey))
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
    }

    /// Ends coalescing, so the next edit starts a fresh undo step even if it reuses the key.
    public mutating func endCoalescing() {
        guard !undoStack.isEmpty else { return }
        undoStack[undoStack.count - 1].coalescingKey = nil
    }

    public mutating func undo(current: AnimatedDocument) -> AnimatedDocument? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.insert(Entry(document: current, name: entry.name, coalescingKey: nil), at: 0)
        if redoStack.count > Self.limit { redoStack.removeLast(redoStack.count - Self.limit) }
        return entry.document
    }

    public mutating func redo(current: AnimatedDocument) -> AnimatedDocument? {
        guard !redoStack.isEmpty else { return nil }
        let entry = redoStack.removeFirst()
        undoStack.append(Entry(document: current, name: entry.name, coalescingKey: nil))
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        return entry.document
    }

    public mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Exposed for tests and for a host that wants to show "3 steps back".
    public var undoDepth: Int { undoStack.count }
    public var redoDepth: Int { redoStack.count }
}
