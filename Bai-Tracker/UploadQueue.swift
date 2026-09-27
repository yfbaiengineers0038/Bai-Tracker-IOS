import Amplify
import Foundation
import UIKit

/// One attachment waiting to reach S3, described well enough to finish the job
/// after a relaunch.
struct PendingUpload: Codable, Identifiable {
    let id: UUID
    /// The point this attachment belongs to. The point already exists on the
    /// backend — that's what makes resuming possible.
    let pointId: String
    /// Destination S3 key, decided when the item was queued so a retry can't
    /// produce a duplicate object under a new name.
    let key: String
    /// File name inside the queue directory. Not a full path: the container
    /// path changes between launches and app updates.
    let fileName: String
    /// Videos are transcoded by the worker rather than at capture time, so
    /// leaving a screen is instant even for a 90-second clip.
    let needsTranscode: Bool
    var attempts: Int
    let queuedAt: Date
}

/// Durable outbox for point media.
///
/// Uploading straight from a screen meant the work died with it: leaving the
/// sheet, backgrounding, or force-quitting could leave bytes in S3 that no
/// point referenced, or lose the capture entirely. Crews work on bad cellular,
/// so that was the difference between a recorded site visit and a lost one.
///
/// Instead the point is saved first — a small, fast write — and its media is
/// copied somewhere durable and queued. The worker drains the queue one item
/// at a time, attaching each key to the point as it lands. Anything unfinished
/// is picked up on the next launch, so a force-quit costs at most the bytes of
/// the item in flight.
///
/// Serial by design: parallel uploads would compete for a weak uplink, and the
/// read-modify-write that appends a key to a point's `photos` has no atomic
/// form in AppSync, so overlapping writes could drop one.
@MainActor
final class UploadQueue {

    static let shared = UploadQueue()

    /// Fires whenever the queue changes, so the map can show what's left.
    var onChange: (() -> Void)?

    /// Fires with a point id once one of its attachments is attached, so an
    /// open screen can refresh.
    var onAttach: ((String) -> Void)?

    private(set) var pending: [PendingUpload] = []

    /// Where the item currently uploading is up to, 0...1, for the banner.
    private(set) var currentFraction: Double?

    private var isDraining = false
    /// Retry backoff, so a dead uplink isn't hammered.
    private static let retryDelays: [TimeInterval] = [2, 10, 30, 120, 300]

    private let directory: URL
    private let manifest: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        directory = base.appendingPathComponent("PendingUploads", isDirectory: true)
        manifest = directory.appendingPathComponent("queue.json")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        load()
    }

    var pendingCount: Int { pending.count }

    // MARK: - Enqueue

    /// Copies `file` somewhere durable and queues it for `pointId`.
    ///
    /// Takes ownership of `file`: it's moved when possible, so callers must not
    /// delete it afterwards.
    func enqueue(file: URL, key: String, pointId: String, needsTranscode: Bool) {
        let id = UUID()
        let name = "\(id.uuidString).\(file.pathExtension.isEmpty ? "dat" : file.pathExtension)"
        let destination = directory.appendingPathComponent(name)

        do {
            // Move rather than copy where we can: the source is usually our own
            // scratch file, and this avoids a second copy of a large video.
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            guard (try? FileManager.default.copyItem(at: file, to: destination)) != nil else {
                Self.log("couldn't stage \(key): \(error.localizedDescription)")
                return
            }
        }

        pending.append(PendingUpload(id: id, pointId: pointId, key: key,
                                     fileName: name, needsTranscode: needsTranscode,
                                     attempts: 0, queuedAt: Date()))
        save()
        onChange?()
        start()
    }

    /// Queues already-encoded bytes (a photo) by writing them out first.
    func enqueue(data: Data, key: String, pointId: String) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString).jpg")
        guard (try? data.write(to: scratch)) != nil else {
            Self.log("couldn't write bytes for \(key)")
            return
        }
        enqueue(file: scratch, key: key, pointId: pointId, needsTranscode: false)
    }

    /// Drops an item and its file — used when a point is deleted out from under
    /// its uploads.
    func cancelAll(forPoint pointId: String) {
        let doomed = pending.filter { $0.pointId == pointId }
        pending.removeAll { $0.pointId == pointId }
        for item in doomed {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.fileName))
        }
        save()
        onChange?()
    }

    // MARK: - Draining

    /// Kicks the worker. Safe to call repeatedly — from launch, from
    /// foregrounding, or after queueing.
    func start() {
        guard !isDraining, !pending.isEmpty else { return }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        defer {
            isDraining = false
            currentFraction = nil
            onChange?()
        }

        while let item = pending.first {
            // Ask iOS for time so backgrounding mid-item doesn't cut the
            // metadata write in half. Expiry just ends the assertion; the item
            // stays queued and resumes next launch.
            let assertion = UIApplication.shared.beginBackgroundTask(withName: "UploadQueue")
            let outcome = await send(item)
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }

            switch outcome {
            case .done:
                remove(item)

            case .giveUp(let reason):
                Self.log("dropping \(item.key): \(reason)")
                remove(item)

            case .retry(let reason):
                var updated = item
                updated.attempts += 1
                if let index = pending.firstIndex(where: { $0.id == item.id }) {
                    pending[index] = updated
                }
                save()
                onChange?()

                let delay = Self.retryDelays[min(updated.attempts - 1, Self.retryDelays.count - 1)]
                Self.log("retrying \(item.key) in \(Int(delay))s: \(reason)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // A later launch or a foreground event may have started another
                // drain while we slept; let that one take over.
                if pending.first?.id != item.id { continue }
            }
        }
    }

    private enum Outcome {
        case done
        /// Worth another attempt — network, timeout, server hiccup.
        case retry(String)
        /// Never going to work: the file or the point is gone.
        case giveUp(String)
    }

    private func send(_ item: PendingUpload) async -> Outcome {
        let file = directory.appendingPathComponent(item.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .giveUp("staged file missing")
        }

        // Transcode here rather than at capture time so leaving a screen is
        // instant. The original stays queued until the upload succeeds, so a
        // kill mid-transcode just repeats this step.
        var upload = file
        var scratch: [URL] = []
        if item.needsTranscode {
            let prepared = await MediaPipeline.prepareVideo(at: file)
            upload = prepared.url
            // Never delete the queued original here; only the transcode.
            scratch = prepared.scratchURLs.filter { $0 != file }
        }
        defer { MediaPipeline.discardScratch(scratch) }

        do {
            try await MediaPipeline.uploadFile(
                at: upload,
                key: item.key,
                onStart: { _ in },
                onProgress: { [weak self] fraction, _, _ in
                    Task { @MainActor in
                        self?.currentFraction = fraction
                        self?.onChange?()
                    }
                })
        } catch {
            let text = String(describing: error).lowercased()
            if text.contains("cancel") { return .retry("cancelled") }
            return .retry(error.localizedDescription)
        }

        // Bytes are up; now make the point point at them. Until this lands the
        // object is orphaned, which is why it's retried rather than dropped.
        do {
            try await attach(key: item.key, toPoint: item.pointId)
        } catch let error as AttachError {
            switch error {
            case .pointGone:
                await MediaPipeline.deleteOrphan(key: item.key)
                return .giveUp("point no longer exists")
            case .failed(let message):
                return .retry("attach failed: \(message)")
            }
        } catch {
            return .retry("attach failed: \(error.localizedDescription)")
        }

        onAttach?(item.pointId)
        return .done
    }

    private func remove(_ item: PendingUpload) {
        pending.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.fileName))
        save()
        onChange?()
    }

    // MARK: - Attaching a key to its point

    private enum AttachError: Error {
        case pointGone
        case failed(String)
    }

    /// Appends `key` to the point's `photos`.
    ///
    /// Reads the current list first: AppSync has no atomic list append, so a
    /// blind write would clobber anything added since. Safe because the queue
    /// is serial.
    private func attach(key: String, toPoint pointId: String) async throws {
        struct Fetched: Decodable { let id: String; let photos: [String]? }
        struct GetResponse: Decodable { let getPoint: Fetched? }

        let get = GraphQLRequest<GetResponse>(
            document: "query GetPoint($id: ID!) { getPoint(id: $id) { id photos } }",
            variables: ["id": pointId],
            responseType: GetResponse.self)

        let current: [String]
        do {
            let result = try await Amplify.API.query(request: get)
            guard case .success(let data) = result else {
                throw AttachError.failed("couldn't read the point")
            }
            guard let point = data.getPoint else { throw AttachError.pointGone }
            current = point.photos ?? []
        } catch let error as AttachError {
            throw error
        } catch {
            throw AttachError.failed(error.localizedDescription)
        }

        // A retry after a successful upload but a failed attach would otherwise
        // add the same key twice.
        guard !current.contains(key) else { return }

        struct Updated: Decodable { let id: String }
        struct UpdateResponse: Decodable { let updatePoint: Updated }
        let update = GraphQLRequest<UpdateResponse>(
            document: """
            mutation UpdatePoint($input: UpdatePointInput!) {
              updatePoint(input: $input) { id }
            }
            """,
            variables: ["input": ["id": pointId, "photos": current + [key]]],
            responseType: UpdateResponse.self)

        do {
            let result = try await Amplify.API.mutate(request: update)
            guard case .success = result else {
                throw AttachError.failed("the point rejected the update")
            }
        } catch let error as AttachError {
            throw error
        } catch {
            throw AttachError.failed(error.localizedDescription)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: manifest),
              let saved = try? JSONDecoder().decode([PendingUpload].self, from: data) else {
            return
        }
        // Drop entries whose file vanished — an app update or a cleaning tool
        // can take the container with it.
        pending = saved.filter {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0.fileName).path)
        }
        if pending.count != saved.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: manifest, options: .atomic)
    }

    private static func log(_ message: String) {
        print("[UploadQueue] \(message)")
    }
}
