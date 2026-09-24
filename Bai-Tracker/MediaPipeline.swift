import AVFoundation
import Amplify
import Foundation

/// Shared media pipeline for point attachments.
///
/// Field crews are often on weak site uplinks, so raw camera footage is the
/// app's biggest reliability risk: a 3-minute 4K clip picked from the library
/// is a ~700 MB upload. This shrinks what we send, reports progress while it
/// sends, allows cancelling, and cleans up after itself.
enum MediaPipeline {

    // MARK: - Limits

    /// Longest in-app recording. A minute of 1080p is already ~110 MB.
    static let maxRecordingDuration: TimeInterval = 90

    /// Export preset for uploads. H.264 1080p keeps the output playable
    /// everywhere (reports, Windows, older players).
    /// `AVAssetExportPresetHEVC1920x1080` would roughly halve the size again
    /// if every consumer of this footage supports HEVC.
    private static let exportPreset = AVAssetExportPreset1920x1080

    /// Only keep a re-encode if it actually saves something worth the wait.
    private static let minimumUsefulSaving = 0.10

    // MARK: - Video preparation

    /// A video ready to upload, plus the scratch files we made getting there.
    struct PreparedVideo {
        let url: URL
        let byteCount: Int64
        let originalByteCount: Int64
        let didShrink: Bool
        /// Temp files safe to delete once the upload finishes.
        let scratchURLs: [URL]

        /// e.g. 0.78 when the re-encode saved 78% of the bytes.
        var savedFraction: Double {
            guard originalByteCount > 0, didShrink else { return 0 }
            return 1 - (Double(byteCount) / Double(originalByteCount))
        }
    }

    /// Re-encodes `source` to 1080p when that meaningfully shrinks it.
    ///
    /// Falls back to the original file whenever the export fails or doesn't
    /// pay for itself, so this can never block an upload.
    static func prepareVideo(at source: URL) async -> PreparedVideo {
        let originalBytes = byteCount(of: source)

        guard let transcoded = await transcode(source) else {
            return PreparedVideo(url: source,
                                 byteCount: originalBytes,
                                 originalByteCount: originalBytes,
                                 didShrink: false,
                                 scratchURLs: [source])
        }

        let newBytes = byteCount(of: transcoded)
        let saved = originalBytes > 0 ? 1 - (Double(newBytes) / Double(originalBytes)) : 0

        // A re-encode that isn't clearly smaller isn't worth the quality hit.
        guard newBytes > 0, saved >= minimumUsefulSaving else {
            try? FileManager.default.removeItem(at: transcoded)
            return PreparedVideo(url: source,
                                 byteCount: originalBytes,
                                 originalByteCount: originalBytes,
                                 didShrink: false,
                                 scratchURLs: [source])
        }

        return PreparedVideo(url: transcoded,
                             byteCount: newBytes,
                             originalByteCount: originalBytes,
                             didShrink: true,
                             scratchURLs: [source, transcoded])
    }

    private static func transcode(_ source: URL) async -> URL? {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: exportPreset) else {
            return nil
        }

        // .mp4 where supported so the extension matches what we store; the
        // app treats .mp4 and .mov alike when playing media back.
        let fileType: AVFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).\(fileType == .mp4 ? "mp4" : "mov")")

        session.outputURL = output
        session.outputFileType = fileType
        // Front-load the moov atom so the file streams instead of needing a
        // full download before it plays.
        session.shouldOptimizeForNetworkUse = true

        if #available(iOS 18.0, *) {
            do {
                try await session.export(to: output, as: fileType)
            } catch {
                try? FileManager.default.removeItem(at: output)
                return nil
            }
        } else {
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            guard session.status == .completed else {
                try? FileManager.default.removeItem(at: output)
                return nil
            }
        }

        return FileManager.default.fileExists(atPath: output.path) ? output : nil
    }

    // MARK: - Upload

    /// Uploads a file to S3, reporting progress as it goes.
    ///
    /// `onStart` hands back the Amplify task so the caller can cancel it.
    /// Progress arrives as plain numbers rather than a `Progress` object to
    /// keep it safe to hop actors.
    static func uploadFile(
        at url: URL,
        key: String,
        onStart: (StorageUploadFileTask) -> Void,
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void
    ) async throws {
        let task = Amplify.Storage.uploadFile(path: .fromString(key), local: url)
        onStart(task)

        let monitor = Task {
            for await progress in await task.inProcess {
                onProgress(progress.fractionCompleted,
                           progress.completedUnitCount,
                           progress.totalUnitCount)
            }
        }
        defer { monitor.cancel() }

        _ = try await task.value
    }

    /// Removes an object we uploaded but then failed to attach to a point, so
    /// the bucket doesn't accumulate files no record points at.
    static func deleteOrphan(key: String) async {
        _ = try? await Amplify.Storage.remove(path: .fromString(key))
    }

    // MARK: - Housekeeping

    /// Deletes scratch files we copied or generated in the temp directory.
    static func discardScratch(_ urls: [URL]) {
        for url in urls where url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func byteCount(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "45% · 52.1 MB of 114.8 MB"
    static func progressText(fraction: Double, sent: Int64, total: Int64) -> String {
        let percent = Int((fraction * 100).rounded())
        guard total > 0 else { return "Uploading… \(percent)%" }
        return "Uploading \(percent)% · \(format(bytes: sent)) of \(format(bytes: total))"
    }
}
