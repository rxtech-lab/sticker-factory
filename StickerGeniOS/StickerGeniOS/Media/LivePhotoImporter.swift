import AVFoundation
import CoreGraphics
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import os

nonisolated enum LivePhotoImportError: Error, LocalizedError {
    case unreadableImage
    case unreadableVideo

    var errorDescription: String? {
        switch self {
        case .unreadableImage: String(localized: "That photo could not be read.")
        case .unreadableVideo: String(localized: "The motion from that Live Photo could not be read.")
        }
    }
}

/// A photo the user picked, plus the paired video if it turned out to have one.
///
/// `videoURL` being nil is an ordinary outcome, not a failure: the user may have picked a still, or
/// the Live Photo's video may be unavailable because the library is iCloud-optimised and offline.
/// Everything downstream is written to work either way, and a still simply yields a one-frame atlas.
nonisolated struct LivePhotoCapture: Sendable, Identifiable {
    /// Identity for `sheet(item:)`. A fresh id per import, because two picks of the same photo are
    /// two separate decisions and the second must reopen the sheet.
    let id = UUID()
    var still: CGImage
    var videoURL: URL?
    /// The instant the still corresponds to, read from the video's `still-image-time` metadata.
    /// Sampling is centred here because it is the frame the user was looking at when they chose a
    /// subject, so it is where the mask they picked is exactly right.
    var stillTimeSeconds: Double?

    var hasMotion: Bool { videoURL != nil }
}

/// Pulls a `LivePhotoCapture` out of whatever `PhotosPicker` hands back.
///
/// Deliberately a ladder that always has a rung left. Getting the *paired video* out of a picked
/// Live Photo is the least certain step in this whole feature — it depends on `PHLivePhoto` being
/// transferable and on `PHAssetResourceManager` serving a picker-vended object without a separate
/// library authorization — so each rung falls through to the next, and the last one is the ordinary
/// still path that already shipped. A user whose device refuses every motion rung still gets a
/// working subject lift; they just get one frame of it.
@MainActor
enum LivePhotoImporter {
    static func capture(from item: PhotosPickerItem) async throws -> LivePhotoCapture {
        SubjectLiftLog.logger.info("import: starting")
        // Rung 1: the paired video resource behind a PHLivePhoto.
        if let livePhoto = try? await item.loadTransferable(type: PHLivePhoto.self),
           let capture = await capture(from: livePhoto) {
            SubjectLiftLog.logger.info(
                "import: rung 1 (PHLivePhoto) succeeded, motion=\(capture.hasMotion, privacy: .public)"
            )
            return capture
        }
        SubjectLiftLog.logger.info("import: rung 1 (PHLivePhoto) unavailable, trying movie")

        // Rung 2: the item as a movie. Some pickers vend the video component directly.
        if let movie = try? await item.loadTransferable(type: LivePhotoMovie.self) {
            if let still = try? await stillImage(from: item) {
                SubjectLiftLog.logger.info("import: rung 2 (movie + still) succeeded")
                return .init(still: still, videoURL: movie.url, stillTimeSeconds: await stillTime(of: movie.url))
            }
            // No still, but a video: use its first frame as the still so the interactive pick has
            // something to run on.
            if let poster = try? await LivePhotoFrameExtractor.firstFrame(of: movie.url) {
                SubjectLiftLog.logger.info("import: rung 2 (movie, poster frame) succeeded")
                return .init(still: poster, videoURL: movie.url, stillTimeSeconds: await stillTime(of: movie.url))
            }
        }

        // Rung 3: a still, which is the path that already worked before any of this existed.
        SubjectLiftLog.logger.info("import: rung 3 (still only), no motion available")
        return .init(still: try await stillImage(from: item), videoURL: nil, stillTimeSeconds: nil)
    }

    private static func stillImage(from item: PhotosPickerItem) async throws -> CGImage {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = upright(data)
        else { throw LivePhotoImportError.unreadableImage }
        return image
    }

    /// The photo's pixels, rotated the way the photo is meant to be seen.
    ///
    /// A `CGImage` carries no orientation — that lives on the `UIImage` wrapping it — so taking
    /// `.cgImage` off a camera photo hands back the sensor's raw buffer, which for anything shot in
    /// portrait is a quarter turn out. Every consumer below this point is CoreGraphics and would
    /// inherit that: the sheet shows the photo sideways, and the segmenter is asked to find a
    /// subject in an image no camera would ever have produced. Baking the rotation in once here is
    /// what keeps the rest of the pipeline free of an orientation it would only have to re-apply.
    private static func upright(_ data: Data) -> CGImage? {
        guard let image = UIImage(data: data) else { return nil }
        guard image.imageOrientation != .up else { return image.cgImage }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }

    private static func capture(from livePhoto: PHLivePhoto) async -> LivePhotoCapture? {
        let resources = PHAssetResource.assetResources(for: livePhoto)
        guard let video = resources.first(where: { $0.type == .pairedVideo })
            ?? resources.first(where: { $0.type == .fullSizePairedVideo }),
            let still = await stillImage(from: resources)
        else { return nil }
        guard let url = try? await write(video) else {
            SubjectLiftLog.logger.warning("import: paired video found but could not be written; falling back to a still")
            // The still is still usable, so degrade to a one-frame lift rather than failing the pick.
            return .init(still: still, videoURL: nil, stillTimeSeconds: nil)
        }
        return .init(still: still, videoURL: url, stillTimeSeconds: await stillTime(of: url))
    }

    private static func stillImage(from resources: [PHAssetResource]) async -> CGImage? {
        guard let photo = resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizePhoto })
        else { return nil }
        guard let url = try? await write(photo), let data = try? Data(contentsOf: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return upright(data)
    }

    /// Streams a resource to a temp file.
    ///
    /// `isNetworkAccessAllowed` matters more than it looks: on a library set to optimise storage,
    /// the paired video may only exist in iCloud, and without this the request fails rather than
    /// downloading — which would make the whole feature look broken on exactly the devices most
    /// likely to have it enabled.
    private static func write(_ resource: PHAssetResource) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "live-\(UUID().uuidString).\(resource.type == .photo ? "heic" : "mov")")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return url
    }

    /// The timestamp of the frame shown as the Live Photo's still.
    ///
    /// A Live Photo's paired video carries a `com.apple.quicktime.still-image-time` marker on a
    /// metadata track, identifying the instant the visible photo was taken from. That is where
    /// sampling is centred, because it is the frame the user chose their subject on.
    ///
    /// Returns nil freely: the marker is a convention rather than a guarantee, and every caller
    /// falls back to the midpoint of the clip, which is close enough that the difference is a frame
    /// or two of a 1.2-second window.
    private static func stillTime(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .metadata) else { return nil }
        for track in tracks {
            guard let segments = try? await track.load(.segments) else { continue }
            for segment in segments where segment.timeMapping.target.start.isNumeric {
                let time = segment.timeMapping.target.start.seconds
                if time.isFinite, time >= 0 { return time }
            }
        }
        return nil
    }
}

/// A movie the picker vends, copied somewhere we control.
///
/// The copy is not optional: `FileRepresentation`'s imported file is deleted the moment the closure
/// returns, so keeping the URL without copying hands the caller a path to nothing.
nonisolated struct LivePhotoMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .quickTimeMovie) { received in
            let copy = FileManager.default.temporaryDirectory
                .appending(path: "live-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
        FileRepresentation(importedContentType: .movie) { received in
            let copy = FileManager.default.temporaryDirectory
                .appending(path: "live-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
