import Foundation
import os

/// Tracing for the subject-lift path.
///
/// This flow leans on more system behaviour than anything else in the app — whether a picked item
/// vends a paired video, whether Vision finds instances in a given photo, whether a frame
/// segments — and every one of those failures degrades quietly by design. That is right for the
/// user and useless for anyone trying to work out why they got a still instead of motion, so each
/// decision says which way it went and why.
///
/// The categories worth knowing: `import:` which picker rung won and whether motion survived it,
/// `segment:` what Vision returned and how many candidates cleared the area floor, `stage:` what
/// the user's touch selected, `pipeline:` frames extracted versus frames lifted.
///
/// Read with: `xcrun simctl spawn booted log stream --predicate 'category == "subject-lift"'`,
/// or filter Console.app on the same category with a device attached.
nonisolated enum SubjectLiftLog {
    static let logger = Logger(subsystem: "app.rxlab.sticker-factory", category: "subject-lift")
}
