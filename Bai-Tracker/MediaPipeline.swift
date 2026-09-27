import AVFoundation
import Amplify
import Foundation
import UIKit

/// Shared media pipeline for point attachments.
///
/// Field crews are often on weak site uplinks, so raw camera footage is the
/// app's biggest reliability risk: a 3-minute 4K clip picked from the library
/// is a ~700 MB upload. This shrinks what we send, reports progress while it
/// sends, allows cancelling, and cleans up after itself.
enum MediaPipeline {

    // MARK: - Limits

    /// Longest in-app recording. At the target below that's about 28 MB.
    static let maxRecordingDuration: TimeInterval = 90

    // MARK: - Upload target
    //
    // The camera records 1080p H.264 at roughly 15 Mbps — a 15-second clip is
    // 27 MB, which is a minute and a half on a 2 Mbps site uplink and far
    // worse on a weak one.
    //
    // `AVAssetExportSession` can't help here: its presets choose their own
    // bitrate, so exporting 1080p re-encodes at about the same size the camera
    // already produced, saves nothing, and gets discarded. Hence the
    // reader/writer pass below, which is the only way to set the bitrate.
    //
    // 720p at 2.5 Mbps is ~6x smaller and still reads a pipe label or a meter
    // face. Audio drops to mono AAC, which is plenty for talking over a clip.

    /// Longest edge of the uploaded video. Portrait clips get 720 wide.
    private static let targetLongEdge: CGFloat = 1280

    private static let targetVideoBitrate = 2_500_000
    private static let targetAudioBitrate = 64_000
    private static let targetAudioSampleRate = 44_100.0

    /// Only keep a re-encode if it actually saves something worth the wait.
    private static let minimumUsefulSaving = 0.10

    // MARK: - Photo target
    //
    // The camera shoots 12 MP (4032x3024), which encoded at 0.8 was a 2.8 MB
    // upload per photo — about 12 seconds each on a 2 Mbps site uplink, so a
    // five-photo point took a minute.
    //
    // 2048 px is ~3 MP: more than a report page or any screen resolves, and
    // label text stays legible. Measured on real field photos, this lands
    // around 650 KB, roughly 4x smaller.

    private static let photoLongEdge: CGFloat = 2048
    private static let photoQuality: CGFloat = 0.70

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

    /// Re-encodes `source` to the upload target when that meaningfully shrinks
    /// it.
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

    /// Re-encodes to H.264 at `targetVideoBitrate`, scaled so the longest edge
    /// is `targetLongEdge`.
    ///
    /// H.264 rather than HEVC so the output plays everywhere it might end up —
    /// reports, Windows, older players. HEVC would roughly halve the size
    /// again if every consumer supported it.
    ///
    /// Returns nil on any failure; the caller then uploads the original.
    private static func transcode(_ source: URL) async -> URL? {
        let asset = AVURLAsset(url: source)

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return nil
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).mp4")
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else {
            return nil
        }
        // Front-load the moov atom so the file streams instead of needing a
        // full download before it plays.
        writer.shouldOptimizeForNetworkUse = true

        // MARK: Video

        guard let naturalSize = try? await videoTrack.load(.naturalSize),
              let transform = try? await videoTrack.load(.preferredTransform) else {
            return nil
        }
        // Encode at the *stored* (unrotated) size and carry the rotation over
        // as a transform, exactly as the camera does. A portrait clip is
        // stored 1920x1080 with a 90° transform; encoding at the rotated
        // 1080x1920 and also copying the transform would rotate it twice and
        // stretch the picture. The writer never rotates pixels itself, so the
        // transform is the only thing that should express orientation.
        let target = scaled(width: naturalSize.width, height: naturalSize.height)

        let videoOut = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(target.width),
            AVVideoHeightKey: Int(target.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetVideoBitrate,
                // One keyframe per second: seeking stays usable and the
                // encoder isn't forced to spend bitrate on them.
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        // The writer applies the rotation itself, so frames arrive upright.
        videoOut.transform = transform
        videoOut.expectsMediaDataInRealTime = false

        let videoIn = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard reader.canAdd(videoIn), writer.canAdd(videoOut) else { return nil }
        reader.add(videoIn)
        writer.add(videoOut)

        // MARK: Audio (optional — a clip may be silent)

        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            let audioOut = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: targetAudioSampleRate,
                AVEncoderBitRateKey: targetAudioBitrate,
            ])
            audioOut.expectsMediaDataInRealTime = false
            let audioIn = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
            ])
            if reader.canAdd(audioIn), writer.canAdd(audioOut) {
                reader.add(audioIn)
                writer.add(audioOut)
                audioPair = (audioIn, audioOut)
            }
        }

        guard reader.startReading(), writer.startWriting() else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        writer.startSession(atSourceTime: .zero)

        // Each track pumps on its own queue; the writer interleaves them.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(videoIn, into: videoOut, label: "video") }
            if let (audioIn, audioOut) = audioPair {
                group.addTask { await pump(audioIn, into: audioOut, label: "audio") }
            }
        }

        guard reader.status != .failed else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            return nil
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        return FileManager.default.fileExists(atPath: output.path) ? output : nil
    }

    /// Fits `width`x`height` inside `targetLongEdge`, never upscaling, with
    /// even dimensions because H.264 requires them.
    private static func scaled(width: CGFloat, height: CGFloat) -> CGSize {
        guard width > 0, height > 0 else {
            return CGSize(width: targetLongEdge, height: targetLongEdge * 9 / 16)
        }
        let longest = max(width, height)
        let scale = min(1, targetLongEdge / longest)
        let w = (width * scale).rounded()
        let h = (height * scale).rounded()
        return CGSize(width: max(2, w - w.truncatingRemainder(dividingBy: 2)),
                      height: max(2, h - h.truncatingRemainder(dividingBy: 2)))
    }

    /// Copies every sample from one track into its writer input, waiting
    /// whenever the input's buffer is full.
    ///
    /// `requestMediaDataWhenReady` re-invokes its block each time the input
    /// drains, so `finished` guards against resuming the continuation twice —
    /// which would trap. The block runs on one serial queue, so a plain flag
    /// is enough.
    private static func pump(_ input: AVAssetReaderTrackOutput,
                             into output: AVAssetWriterInput,
                             label: String) async {
        let queue = DispatchQueue(label: "MediaPipeline.\(label)")
        await withCheckedContinuation { continuation in
            var finished = false
            output.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while output.isReadyForMoreMediaData {
                    guard let sample = input.copyNextSampleBuffer(),
                          output.append(sample) else {
                        finished = true
                        output.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    // MARK: - Photo preparation

    /// JPEG bytes for upload: downscaled to `photoLongEdge` and encoded at
    /// `photoQuality`.
    ///
    /// Never upscales, so a photo that's already small passes through at its
    /// own size. Falls back to encoding at full size if the redraw fails, so
    /// this can't stop an upload.
    ///
    /// `UIGraphicsImageRenderer` bakes in the orientation, which also strips
    /// EXIF — including any GPS the camera attached. The point carries its own
    /// coordinates, so nothing is lost that we use, and it's one less way for
    /// a photo to leak a location once it's out of the app.
    static func photoData(from image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > photoLongEdge else {
            return image.jpegData(compressionQuality: photoQuality)
        }

        let scale = photoLongEdge / longest
        let target = CGSize(width: (image.size.width * scale).rounded(),
                            height: (image.size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1          // target is already in pixels
        format.opaque = true      // photos have no alpha; skips a blend
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: photoQuality)
            ?? image.jpegData(compressionQuality: photoQuality)
    }

    // MARK: - Object keys

    /// Prefix every attachment is stored under.
    ///
    /// One flat prefix is safe because the bucket grants `get` but not `list`
    /// to ordinary members: the only way to reach an object is to know its
    /// UUID key, and keys only appear on point records the caller is already
    /// authorized to read.
    static let mediaPrefix = "point-photos"

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
