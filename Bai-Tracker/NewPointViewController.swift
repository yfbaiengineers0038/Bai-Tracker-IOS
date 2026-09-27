import UIKit
import CoreLocation
import PhotosUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import Amplify

final class NewPointViewController: UIViewController {

    weak var delegate: PointDetailDelegate?

    private let coordinate: CLLocationCoordinate2D

    /// Media captured but not yet uploaded, in capture order. Everything here
    /// goes up together when the user taps Finish.
    private var pendingItems: [PendingMedia] = []

    /// Live voice-memo recorder; non-nil only while recording.
    private var audioRecorder: AVAudioRecorder?
    /// Ticks the elapsed-time readout while recording.
    private var recordingTimer: Timer?

    // MARK: - Controls

    private let datePicker: UIDatePicker = {
        let p = UIDatePicker()
        p.datePickerMode = .date
        p.preferredDatePickerStyle = .compact
        p.tintColor = .appPurple
        return p
    }()

    private let timePicker: UIDatePicker = {
        let p = UIDatePicker()
        p.datePickerMode = .time
        p.preferredDatePickerStyle = .compact
        p.tintColor = .appPurple
        return p
    }()

    private let locationField: UITextField = {
        let f = UITextField()
        f.placeholder = "Name"
        f.borderStyle = .roundedRect
        f.font = .systemFont(ofSize: 16)
        return f
    }()

    private let descriptionField: UITextField = {
        let f = UITextField()
        f.placeholder = "Description"
        f.borderStyle = .roundedRect
        f.font = .systemFont(ofSize: 16)
        return f
    }()

    private let categoryField = CategoryPickerView()

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textAlignment = .center
        l.numberOfLines = 0
        l.isHidden = true
        return l
    }()

    private let photoButton = UIButton(type: .system)
    private let videoButton = UIButton(type: .system)
    private let uploadButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)

    /// Everything captured but not yet uploaded. Hidden while empty.
    private let pendingTray = PendingMediaTray()

    // MARK: - Init

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "New Point"
        buildLayout()
    }

    // MARK: - Layout

    private func buildLayout() {
        let coordLabel = UILabel()
        coordLabel.font = .systemFont(ofSize: 12)
        coordLabel.textColor = .secondaryLabel
        coordLabel.text = String(format: "lat %.6f  lng %.6f", coordinate.latitude, coordinate.longitude)

        let dateRow = labeledRow(label: "Date", control: datePicker)
        let timeRow = labeledRow(label: "Time", control: timePicker)
        let locRow  = labeledColumn(label: "Name",         field: locationField)
        let descRow = labeledColumn(label: "Description", field: descriptionField)
        // CategoryPickerView renders its own label, so add it directly.
        let catRow  = categoryField

        // Audio records a voice memo; Cancel discards. Saving now lives on
        // Upload, which commits the form and closes the sheet.
        configureMediaButton(audioButton, title: "Audio", systemImage: "mic")
        audioButton.addTarget(self, action: #selector(toggleAudioRecording), for: .touchUpInside)
        let cancelBtn = makeButton(title: "Cancel", color: .systemGray, action: #selector(cancel))
        let actionRow = hStack([audioButton, cancelBtn])

        // Media buttons (Photo / Video / Upload)
        configureMediaButton(photoButton, title: "Photo", systemImage: "camera")
        configureMediaButton(videoButton, title: "Video", systemImage: "video")
        configureMediaButton(uploadButton, title: "Finish", systemImage: "icloud.and.arrow.up")
        photoButton.addTarget(self, action: #selector(addPhoto), for: .touchUpInside)
        videoButton.addTarget(self, action: #selector(addVideo), for: .touchUpInside)
        uploadButton.addTarget(self, action: #selector(uploadAndSave), for: .touchUpInside)
        let mediaButtonsRow = hStack([photoButton, videoButton, uploadButton])

        pendingTray.onRemove = { [weak self] index in self?.removeStaged(at: index) }

        let stack = UIStackView(arrangedSubviews: [
            coordLabel, dateRow, timeRow, locRow, descRow, catRow,
            mediaButtonsRow, pendingTray,
            statusLabel, actionRow
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -40)
        ])
    }

    // MARK: - Actions

    /// Commits the point, then hands its media to the upload queue and closes.
    ///
    /// The point is saved first because it's small and fast; media is queued
    /// rather than awaited, so the sheet closes immediately and the crew can
    /// walk to the next location while the clip is still going up. Anything
    /// unfinished survives leaving the screen, backgrounding, or a force-quit.
    @objc private func uploadAndSave() {
        // A recording still running would otherwise be lost on dismiss.
        if audioRecorder?.isRecording == true { stopRecording() }

        guard let projectId = ProjectStore.shared.current?.id else {
            showStatus("Select a project before creating a point.", color: .systemOrange)
            return
        }

        uploadButton.isEnabled = false
        showStatus("Saving…", color: .secondaryLabel)

        Task {
            guard let created = await createPoint(id: nil, projectId: projectId,
                                                  initialKeys: nil) else {
                uploadButton.isEnabled = true
                showStatus("Failed to create point.", color: .systemRed)
                return
            }

            let queued = queueStagedMedia(forPoint: created.id)
            delegate?.pointDetailDidCreate(created)

            if queued > 0 {
                showStatus("Saved. \(queued) item\(queued == 1 ? "" : "s") uploading…",
                           color: .systemGreen)
            }
            dismiss(animated: true)
        }
    }

    /// Hands every staged capture to the queue. Returns how many were queued.
    ///
    /// Photos are encoded here — it's quick, and it means the queue stores
    /// upload-ready bytes. Videos are queued as-is and transcoded by the
    /// worker, so a 90-second clip doesn't hold the sheet open.
    private func queueStagedMedia(forPoint pointId: String) -> Int {
        var queued = 0
        for item in pendingItems {
            switch item.kind {
            case .photo(let image):
                guard let data = MediaPipeline.photoData(from: image) else { continue }
                UploadQueue.shared.enqueue(
                    data: data,
                    key: "\(MediaPipeline.mediaPrefix)/\(UUID().uuidString).jpg",
                    pointId: pointId)

            case .audio(let url):
                UploadQueue.shared.enqueue(
                    file: url,
                    key: "\(MediaPipeline.mediaPrefix)/\(UUID().uuidString).m4a",
                    pointId: pointId,
                    needsTranscode: false)

            case .video(let url):
                let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
                UploadQueue.shared.enqueue(
                    file: url,
                    key: "\(MediaPipeline.mediaPrefix)/\(UUID().uuidString).\(ext)",
                    pointId: pointId,
                    needsTranscode: true)
            }
            queued += 1
        }
        // The queue owns those files now, so don't let `cancel` delete them.
        pendingItems = []
        pendingTray.update(with: pendingItems)
        return queued
    }

    /// Creates the point on the backend. If `initialKeys` is provided, those
    /// are attached as the point's first media (first-upload flow). Returns the
    /// created PointData, or nil on failure.
    private func createPoint(id: String?, projectId: String, initialKeys: [String]?) async -> PointData? {
        let photos = initialKeys ?? []
        var input: [String: Any] = [
            "date":        formatted(datePicker.date, mode: .date),
            "time":        formatted(timePicker.date, mode: .time),
            "location":    locationField.text?.trimmingCharacters(in: .whitespaces) ?? "",
            "description": descriptionField.text?.trimmingCharacters(in: .whitespaces) ?? "",
            "lat":         coordinate.latitude,
            "lng":         coordinate.longitude,
            "photos":      photos,
            "timezone":    TimeZone.current.identifier,
            "category":    categoryField.categoryName?.trimmingCharacters(in: .whitespaces) ?? "",
            "comments":    [],
            "projectId":   projectId
        ]
        // Scope the point to the same group as its project. The backend checks
        // this value against the caller's groups on create, so it's what
        // decides who can see the point — and a member can only ever write a
        // group they belong to.
        if let group = UserSession.shared.groupForRecords(in: ProjectStore.shared.current) {
            input["accessGroup"] = group
        }
        let vars: [String: Any] = ["input": input]

        let mutation = """
        mutation CreatePoint($input: CreatePointInput!) {
          createPoint(input: $input) {
            id date time location description lat lng photos timezone comments category projectId
          }
        }
        """
        struct CreatedPoint: Decodable {
            let id: String; let date: String; let time: String?
            let location: String?; let description: String?
            let lat: Double; let lng: Double; let photos: [String]?
            let timezone: String?; let comments: [String]?; let category: String?
            let projectId: String?
        }
        struct ResponseData: Decodable { let createPoint: CreatedPoint }
        let request = GraphQLRequest<ResponseData>(
            document: mutation, variables: vars, responseType: ResponseData.self)

        do {
            let result = try await Amplify.API.mutate(request: request)
            guard case .success(let data) = result else { return nil }
            let c = data.createPoint
            return PointData(id: c.id, date: c.date, time: c.time,
                             location: c.location, description: c.description,
                             lat: c.lat, lng: c.lng, photos: c.photos ?? [],
                             timezone: c.timezone, comments: c.comments ?? [],
                             category: c.category, projectId: c.projectId)
        } catch { return nil }
    }

    @objc private func cancel() {
        if audioRecorder?.isRecording == true { discardRecording() }
        // Staged captures never made it to S3 — don't leave their scratch
        // files behind in the temp directory.
        MediaPipeline.discardScratch(pendingItems.compactMap(\.fileURL))
        dismiss(animated: true)
    }

    // MARK: - Voice memo

    /// Tap to start recording, tap again to stop. The finished memo drops into
    /// the pending slot and uploads like any other attachment.
    @objc private func toggleAudioRecording() {
        if audioRecorder?.isRecording == true {
            stopRecording()
            return
        }
        ensureAuthorized(.audio) { [weak self] granted in
            guard let self else { return }
            guard granted else { showSettingsAlert(for: "Microphone"); return }
            startRecording()
        }
    }

    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true, options: [])
        } catch {
            showStatus("Couldn't start the microphone.", color: .systemRed)
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else {
                showStatus("Couldn't start recording.", color: .systemRed)
                return
            }
            audioRecorder = recorder
        } catch {
            showStatus("Couldn't start recording: \(error.localizedDescription)", color: .systemRed)
            return
        }

        setAudioButtonRecording(true)
        showStatus("Recording… 0:00", color: .systemRed)
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickRecordingStatus() }
        }
    }

    private func stopRecording() {
        guard let recorder = audioRecorder else { return }
        let url = recorder.url
        let duration = recorder.currentTime
        finishRecording(recorder)

        // Too short to be a usable memo — almost always a mis-tap.
        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: url)
            showStatus("Recording too short — hold the thought and try again.",
                       color: .systemOrange)
            return
        }

        showStatus("Recorded \(Self.durationText(duration)) memo", color: .secondaryLabel)
        // Placeholder stands in for the thumbnail; audio has no frame to show.
        stage(PendingMedia(kind: .audio(url), thumbnail: Self.audioThumbnail()))
    }

    /// Stops and deletes an in-progress recording (used when cancelling).
    private func discardRecording() {
        guard let recorder = audioRecorder else { return }
        let url = recorder.url
        finishRecording(recorder)
        try? FileManager.default.removeItem(at: url)
    }

    /// Shared teardown: stop the recorder, release the session, reset the button.
    private func finishRecording(_ recorder: AVAudioRecorder) {
        recorder.stop()
        audioRecorder = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
        setAudioButtonRecording(false)
    }

    private func tickRecordingStatus() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        showStatus("Recording… \(Self.durationText(recorder.currentTime))", color: .systemRed)
    }

    private func setAudioButtonRecording(_ isRecording: Bool) {
        var c = audioButton.configuration
        c?.title = isRecording ? "Stop" : "Audio"
        c?.image = UIImage(systemName: isRecording ? "stop.fill" : "mic")
        c?.baseBackgroundColor = isRecording ? .systemRed : .appPurple
        audioButton.configuration = c
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Stand-in thumbnail for audio, which has no frame to show.
    /// `nonisolated` so the detail screen's background media fetch can use it.
    nonisolated static func audioThumbnail() -> UIImage {
        let cfg = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        return UIImage(systemName: "waveform", withConfiguration: cfg)?
            .withTintColor(.appPurple, renderingMode: .alwaysOriginal) ?? UIImage()
    }

    // MARK: - Media capture (ported from PointDetailViewController)

    @objc private func addPhoto() {
        let sheet = UIAlertController(title: "Add Photo", message: nil, preferredStyle: .actionSheet)
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            sheet.addAction(UIAlertAction(title: "Take Photo", style: .default) { [weak self] _ in
                self?.takePhoto()
            })
        }
        sheet.addAction(UIAlertAction(title: "Choose from Library", style: .default) { [weak self] _ in
            self?.pickFromLibrary(.images)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    @objc private func addVideo() {
        let sheet = UIAlertController(title: "Add Video", message: nil, preferredStyle: .actionSheet)
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            sheet.addAction(UIAlertAction(title: "Record Video", style: .default) { [weak self] _ in
                self?.recordVideo()
            })
        }
        sheet.addAction(UIAlertAction(title: "Choose from Library", style: .default) { [weak self] _ in
            self?.pickFromLibrary(.videos)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private func takePhoto() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else { self.showSettingsAlert(for: "Camera"); return }
                let picker = UIImagePickerController()
                picker.sourceType = .camera
                picker.cameraCaptureMode = .photo
                picker.mediaTypes = [UTType.image.identifier]
                picker.modalPresentationStyle = .fullScreen
                picker.delegate = self
                self.present(picker, animated: true)
            }
        }
    }

    private func recordVideo() {
        // Camera in video mode needs BOTH camera and microphone access,
        // otherwise the picker fails to present. Resolve both explicitly.
        ensureAuthorized(.video) { [weak self] camOK in
            guard let self else { return }
            guard camOK else { self.showSettingsAlert(for: "Camera"); return }
            self.ensureAuthorized(.audio) { [weak self] micOK in
                guard let self else { return }
                guard micOK else { self.showSettingsAlert(for: "Microphone"); return }
                Self.prepareAudioSession()
                self.presentVideoCamera()
            }
        }
    }

    /// Resolves authorization for a media type, requesting it if undetermined.
    /// Always calls `completion` on the main actor.
    private func ensureAuthorized(_ type: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: type) { granted in
                Task { @MainActor in completion(granted) }
            }
        default: // .denied, .restricted
            DispatchQueue.main.async { completion(false) }
        }
    }

    private func presentVideoCamera() {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]   // must be set BEFORE capture mode
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        // Bound the worst case: the default cap is 10 minutes, which at 1080p
        // is roughly a gigabyte to push over a site connection.
        picker.videoMaximumDuration = MediaPipeline.maxRecordingDuration
        picker.modalPresentationStyle = .fullScreen
        picker.delegate = self
        present(picker, animated: true)
    }

    private func pickFromLibrary(_ filter: PHPickerFilter) {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        // 0 = unlimited: pick a whole set at once, matching the staged-batch
        // flow the camera path uses.
        config.selectionLimit = 0
        config.filter = filter
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    nonisolated private static func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .videoRecording,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
        } catch {
            print("Audio session prepare failed: \(error)")
        }
    }

    private func showSettingsAlert(for feature: String) {
        // Defer so this never collides with an action sheet still dismissing.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(
                title: "\(feature) Access Needed",
                message: "Enable \(feature) access for this app in Settings to use this feature.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self.present(alert, animated: true)
        }
    }

    // MARK: - Staging

    /// Adds a capture to the batch. Nothing is uploaded here — the user keeps
    /// shooting and Finish sends everything in one go.
    private func stage(_ item: PendingMedia) {
        pendingItems.append(item)
        pendingTray.update(with: pendingItems)
        showStatus("\(pendingItems.count) item\(pendingItems.count == 1 ? "" : "s") staged"
                   + " — tap Finish to upload.", color: .secondaryLabel)
    }

    private func removeStaged(at index: Int) {
        guard pendingItems.indices.contains(index) else { return }
        let removed = pendingItems.remove(at: index)
        MediaPipeline.discardScratch(removed.fileURL.map { [$0] } ?? [])
        pendingTray.update(with: pendingItems)
        if pendingItems.isEmpty {
            showStatus("Nothing staged.", color: .secondaryLabel)
        } else {
            showStatus("\(pendingItems.count) item\(pendingItems.count == 1 ? "" : "s") staged"
                       + " — tap Finish to upload.", color: .secondaryLabel)
        }
    }

    /// After a camera capture, offer to keep shooting. This is the point of
    /// staging: several shots in a row, then a single batch upload.
    private func promptForAnotherCapture(isVideo: Bool) {
        let count = pendingItems.count
        let alert = UIAlertController(
            title: isVideo ? "Video Added" : "Photo Added",
            message: "\(count) item\(count == 1 ? "" : "s") staged. Take another,"
                     + " or tap Finish to upload them all at once.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: isVideo ? "Record Another" : "Take Another",
                                      style: .default) { [weak self] _ in
            guard let self else { return }
            if isVideo { recordVideo() } else { takePhoto() }
        })
        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
        present(alert, animated: true)
    }

    nonisolated static func videoThumbnail(from url: URL) -> UIImage? {
        let asset     = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Helpers

    private func formatted(_ date: Date, mode: UIDatePicker.Mode) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Stamp the device's wall clock; the point stores `TimeZone.current`
        // alongside it, and the two have to describe the same reading.
        f.timeZone = .current
        f.dateFormat = mode == .date ? "yyyy-MM-dd" : "HH:mm"
        return f.string(from: date)
    }

    private func showStatus(_ msg: String, color: UIColor) {
        statusLabel.text = msg; statusLabel.textColor = color; statusLabel.isHidden = false
    }

    private func labeledRow(label: String, control: UIView) -> UIStackView {
        let lbl = UILabel()
        lbl.text = label
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = .secondaryLabel
        lbl.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [lbl, UIView(), control])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func labeledColumn(label: String, field: UITextField) -> UIStackView {
        let lbl = UILabel()
        lbl.text = label
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = .secondaryLabel
        let col = UIStackView(arrangedSubviews: [lbl, field])
        col.axis = .vertical
        col.spacing = 4
        return col
    }

    private func makeButton(title: String, color: UIColor, action: Selector) -> UIButton {
        var c = UIButton.Configuration.filled()
        c.title = title; c.baseBackgroundColor = color; c.cornerStyle = .medium
        let b = UIButton(configuration: c)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func hStack(_ views: [UIView]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .horizontal; s.spacing = 10; s.distribution = .fillEqually
        return s
    }

    private func configureMediaButton(_ button: UIButton, title: String, systemImage: String) {
        var c = UIButton.Configuration.filled()
        c.title = title
        c.image = UIImage(systemName: systemImage)
        c.imagePadding = 6
        c.baseBackgroundColor = .appPurple
        c.cornerStyle = .medium
        button.configuration = c
        button.translatesAutoresizingMaskIntoConstraints = false
    }

}

// MARK: - PHPickerViewControllerDelegate (library)

extension NewPointViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)

        // Every selection is staged; loads finish independently, so items can
        // land in a different order than they were picked.
        for result in results {
            let provider = result.itemProvider

            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
                    guard let url else { return }
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + ".mp4")
                    try? FileManager.default.copyItem(at: url, to: dest)
                    let thumbnail = Self.videoThumbnail(from: dest) ?? UIImage()
                    Task { @MainActor [weak self] in
                        self?.stage(PendingMedia(kind: .video(dest), thumbnail: thumbnail))
                    }
                }
            } else if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                    guard let img = obj as? UIImage else { return }
                    Task { @MainActor [weak self] in
                        self?.stage(PendingMedia(kind: .photo(img), thumbnail: img))
                    }
                }
            }
        }
    }
}

// MARK: - UIImagePickerControllerDelegate (camera)

extension NewPointViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        var stagedVideo = false
        if let videoURL = info[.mediaURL] as? URL {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            try? FileManager.default.copyItem(at: videoURL, to: dest)
            let thumbnail = Self.videoThumbnail(from: dest) ?? UIImage()
            stage(PendingMedia(kind: .video(dest), thumbnail: thumbnail))
            stagedVideo = true
        } else if let img = info[.originalImage] as? UIImage {
            stage(PendingMedia(kind: .photo(img), thumbnail: img))
        }

        // Offer another shot from the dismissal completion so the alert never
        // races the camera's own dismissal.
        let fromCamera = picker.sourceType == .camera
        dismiss(animated: true) { [weak self] in
            guard fromCamera else { return }
            self?.promptForAnotherCapture(isVideo: stagedVideo)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss(animated: true) }
}
