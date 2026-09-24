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

    // Media captured but not yet uploaded (single slot, like the detail screen).
    private var pendingImage: UIImage?
    private var pendingVideoURL: URL?
    private var pendingAudioURL: URL?

    /// The running S3 upload, so it can be cancelled mid-flight.
    private var activeUpload: StorageUploadFileTask?

    /// Appears only while an upload is in progress.
    private let cancelUploadButton: UIButton = {
        var c = UIButton.Configuration.plain()
        c.title = "Cancel Upload"
        c.baseForegroundColor = .systemRed
        let b = UIButton(configuration: c)
        b.isHidden = true
        return b
    }()

    /// Live voice-memo recorder; non-nil only while recording.
    private var audioRecorder: AVAudioRecorder?
    /// Ticks the elapsed-time readout while recording.
    private var recordingTimer: Timer?
    // S3 keys + thumbnails collected for items already uploaded.
    private var uploadedKeys: [String] = []
    private var uploadedThumbs: [UIImage] = []
    /// Lazily set on the first upload: the point is created immediately so each
    /// subsequent upload auto-saves to it.
    private var pointId: String?

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

    /// Preview of the just-captured, not-yet-uploaded item, with a play icon
    /// overlay when it's a video. Hidden until media is captured.
    private let mediaPreview: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 8
        iv.backgroundColor = .secondarySystemBackground
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.heightAnchor.constraint(equalToConstant: 160).isActive = true
        iv.isHidden = true
        return iv
    }()

    private let mediaVideoIcon: UIImageView = {
        let cfg = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        let iv = UIImageView(image: UIImage(systemName: "play.circle.fill", withConfiguration: cfg))
        iv.tintColor = .white
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.isHidden = true
        return iv
    }()

    /// One thumbnail chip per already-uploaded item.
    private let uploadedChipsStack: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 8
        s.alignment = .center
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let uploadedLabel: UILabel = {
        let l = UILabel()
        l.text = "Uploaded"
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabel
        l.isHidden = true
        return l
    }()

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
        cancelUploadButton.addTarget(self, action: #selector(cancelUpload), for: .touchUpInside)
        let mediaButtonsRow = hStack([photoButton, videoButton, uploadButton])

        // Video icon overlays centered on the preview.
        mediaPreview.addSubview(mediaVideoIcon)
        NSLayoutConstraint.activate([
            mediaVideoIcon.centerXAnchor.constraint(equalTo: mediaPreview.centerXAnchor),
            mediaVideoIcon.centerYAnchor.constraint(equalTo: mediaPreview.centerYAnchor)
        ])

        uploadedChipsStack.isHidden = true

        let stack = UIStackView(arrangedSubviews: [
            coordLabel, dateRow, timeRow, locRow, descRow, catRow,
            mediaButtonsRow, mediaPreview,
            uploadedLabel, uploadedChipsStack,
            statusLabel, cancelUploadButton, actionRow
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

    /// Commits the point: uploads anything still pending (including a memo the
    /// user just recorded), then saves the form fields and closes the sheet.
    @objc private func uploadAndSave() {
        // A recording still running would otherwise be lost on dismiss.
        if audioRecorder?.isRecording == true { stopRecording() }

        guard pendingImage != nil || pendingVideoURL != nil || pendingAudioURL != nil else {
            save()
            return
        }

        uploadButton.isEnabled = false
        Task {
            await uploadPendingMedia()
            uploadButton.isEnabled = true
            // Only close once the media is safely attached.
            if pendingImage == nil && pendingVideoURL == nil && pendingAudioURL == nil {
                save()
            }
        }
    }

    private func save() {
        guard let projectId = ProjectStore.shared.current?.id else {
            showStatus("Select a project before creating a point.", color: .systemOrange)
            return
        }

        showStatus("Saving…", color: .secondaryLabel)
        Task {
            if let existingId = pointId {
                // Point was already created on first upload — just refresh its
                // fields and dismiss.
                let updated = await refreshPointFields(id: existingId, projectId: projectId)
                await MainActor.run {
                    if let updated { delegate?.pointDetailDidUpdate(updated) }
                    dismiss(animated: true)
                }
            } else {
                // No media was uploaded first — create the point now.
                let created = await createPoint(id: nil, projectId: projectId, initialKey: nil)
                await MainActor.run {
                    if let created {
                        delegate?.pointDetailDidCreate(created)
                        dismiss(animated: true)
                    } else {
                        showStatus("Failed to create point.", color: .systemRed)
                    }
                }
            }
        }
    }

    /// Creates the point on the backend. If `initialKey` is provided, it's
    /// attached as the first photo (first-upload flow). Returns the created
    /// PointData, or nil on failure.
    private func createPoint(id: String?, projectId: String, initialKey: String?) async -> PointData? {
        let photos = initialKey.map { [$0] } ?? uploadedKeys
        let vars: [String: Any] = ["input": [
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
        ]]

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

    /// Pushes the current form fields to an existing point and returns the
    /// refreshed PointData (used on save when the point already exists).
    private func refreshPointFields(id: String, projectId: String) async -> PointData? {
        let vars: [String: Any] = ["input": [
            "id":          id,
            "date":        formatted(datePicker.date, mode: .date),
            "time":        formatted(timePicker.date, mode: .time),
            "location":    locationField.text?.trimmingCharacters(in: .whitespaces) ?? "",
            "description": descriptionField.text?.trimmingCharacters(in: .whitespaces) ?? "",
            "category":    categoryField.categoryName?.trimmingCharacters(in: .whitespaces) ?? "",
            "photos":      uploadedKeys
        ]]
        let mutation = """
        mutation UpdatePoint($input: UpdatePointInput!) {
          updatePoint(input: $input) {
            id date time location description lat lng photos timezone comments category projectId
          }
        }
        """
        struct U: Decodable {
            let id: String; let date: String; let time: String?
            let location: String?; let description: String?
            let lat: Double; let lng: Double; let photos: [String]?
            let timezone: String?; let comments: [String]?; let category: String?
            let projectId: String?
        }
        struct R: Decodable { let updatePoint: U }
        let req = GraphQLRequest<R>(document: mutation, variables: vars, responseType: R.self)
        do {
            let result = try await Amplify.API.mutate(request: req)
            guard case .success(let data) = result else { return nil }
            let u = data.updatePoint
            return PointData(id: u.id, date: u.date, time: u.time,
                             location: u.location, description: u.description,
                             lat: u.lat, lng: u.lng, photos: u.photos ?? [],
                             timezone: u.timezone, comments: u.comments ?? [],
                             category: u.category, projectId: u.projectId)
        } catch { return nil }
    }

    /// Ensures the point exists (creating it lazily on the first upload), then
    /// appends `key` to the point's photos so each upload auto-saves. Returns
    /// the S3 key on success (nil on failure).
    private func ensurePointCreated(addingKey key: String) async -> Bool {
        guard let projectId = ProjectStore.shared.current?.id else {
            await MainActor.run {
                showStatus("Select a project before uploading.", color: .systemOrange)
            }
            return false
        }
        if pointId == nil {
            // First upload → create the point with this media attached.
            let created = await createPoint(id: nil, projectId: projectId, initialKey: key)
            guard let created else {
                await MainActor.run {
                    showStatus("Failed to create point for upload.", color: .systemRed)
                }
                return false
            }
            pointId = created.id
            uploadedKeys = created.photos        // server is source of truth
            // Tell the map about the new point so its marker appears immediately.
            await MainActor.run { delegate?.pointDetailDidCreate(created) }
            return true
        } else {
            // Point already exists → append the key (mirrors PointDetailVC).
            var updated = uploadedKeys
            updated.append(key)
            do {
                try await updatePhotosOnBackend(id: pointId!, photos: updated)
                uploadedKeys = updated
                return true
            } catch {
                await MainActor.run {
                    showStatus("Uploaded but metadata save failed.", color: .systemOrange)
                }
                return false
            }
        }
    }

    /// Appends the photo list to an existing point (mirrors PointDetailVC).
    private func updatePhotosOnBackend(id: String, photos: [String]) async throws {
        let mutation = """
        mutation UpdatePoint($input: UpdatePointInput!) {
          updatePoint(input: $input) { id photos }
        }
        """
        struct P: Decodable { let id: String; let photos: [String]? }
        struct R: Decodable { let updatePoint: P }
        let vars: [String: Any] = ["input": ["id": id, "photos": photos]]
        let req = GraphQLRequest<R>(document: mutation, variables: vars, responseType: R.self)
        let result = try await Amplify.API.mutate(request: req)
        if case .failure(let e) = result {
            throw NSError(domain: "GraphQL", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: String(reflecting: e)])
        }
    }

    @objc private func cancel() {
        if audioRecorder?.isRecording == true { discardRecording() }
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
        // Placeholder stands in for the preview; audio has no frame to show.
        setPendingMedia(image: Self.audioThumbnail(), videoURL: nil, audioURL: url)
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
        config.selectionLimit = 1
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

    private func setPendingMedia(image: UIImage?, videoURL: URL?, audioURL: URL? = nil) {
        pendingImage    = image
        pendingVideoURL = videoURL
        pendingAudioURL = audioURL
        mediaPreview.image    = image
        mediaPreview.isHidden = (image == nil)
        mediaVideoIcon.isHidden = (videoURL == nil)
        // A waveform symbol would be cropped by the photo/video fill mode.
        mediaPreview.contentMode = (audioURL == nil) ? .scaleAspectFill : .scaleAspectFit
        // Auto-upload as soon as media is captured/picked — no Finish tap needed.
        if image != nil {
            uploadMedia()
        }
    }

    nonisolated static func videoThumbnail(from url: URL) -> UIImage? {
        let asset     = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Upload (S3 via Amplify Storage)

    /// Uploads whatever is in the pending slot. Audio is checked first: a memo
    /// carries a placeholder image for the preview, not a real photo.
    private func uploadPendingMedia() async {
        if let audioURL = pendingAudioURL {
            await uploadAudio(audioURL)
        } else if let videoURL = pendingVideoURL {
            await uploadVideo(videoURL)
        } else if let image = pendingImage, let data = image.jpegData(compressionQuality: 0.8) {
            await uploadPhoto(data: data, thumbnail: image)
        }
    }

    /// Auto-upload path used right after capture.
    private func uploadMedia() {
        guard pendingImage != nil || pendingVideoURL != nil || pendingAudioURL != nil else {
            showStatus("Take or choose a photo/video first.", color: .systemOrange); return
        }
        uploadButton.isEnabled = false
        Task {
            await uploadPendingMedia()
            await MainActor.run { uploadButton.isEnabled = true }
        }
    }

    private func uploadPhoto(data: Data, thumbnail: UIImage) async {
        let key = "point-photos/\(UUID().uuidString).jpg"
        showStatus("Uploading photo…", color: .secondaryLabel)
        do {
            _ = try await Amplify.Storage.uploadData(path: .fromString(key), data: data).value
        } catch {
            showStatus("S3 upload failed: \(String(reflecting: error))", color: .systemRed)
            return
        }
        // Auto-save: create the point if needed, then attach this key.
        let saved = await ensurePointCreated(addingKey: key)
        guard saved else {
            await MediaPipeline.deleteOrphan(key: key)
            return
        }
        await MainActor.run {
            uploadedThumbs.append(thumbnail)
            refreshUploadedChips()
            setPendingMedia(image: nil, videoURL: nil)
            showStatus("Upload successful!", color: .systemGreen)
        }
    }

    private func uploadAudio(_ audioURL: URL) async {
        let key = "point-photos/\(UUID().uuidString).m4a"
        setUploadInProgress(true)
        do {
            try await MediaPipeline.uploadFile(
                at: audioURL,
                key: key,
                onStart: { [weak self] task in self?.activeUpload = task },
                onProgress: { [weak self] fraction, sent, total in
                    Task { @MainActor in
                        self?.showStatus(
                            MediaPipeline.progressText(fraction: fraction, sent: sent, total: total),
                            color: .secondaryLabel)
                    }
                })
        } catch {
            setUploadInProgress(false)
            MediaPipeline.discardScratch([audioURL])
            showStatus(uploadFailureMessage(error), color: .systemRed)
            return
        }
        setUploadInProgress(false)

        // Auto-save: create the point if needed, then attach this key.
        let saved = await ensurePointCreated(addingKey: key)
        guard saved else {
            await MediaPipeline.deleteOrphan(key: key)
            MediaPipeline.discardScratch([audioURL])
            return
        }

        MediaPipeline.discardScratch([audioURL])
        await MainActor.run {
            uploadedThumbs.append(Self.audioThumbnail())
            refreshUploadedChips()
            setPendingMedia(image: nil, videoURL: nil)
            showStatus("Voice memo uploaded!", color: .systemGreen)
        }
    }

    private func uploadVideo(_ videoURL: URL) async {
        // Shrink first — this is usually the difference between a 30-second
        // upload and a 5-minute one on a site connection.
        showStatus("Preparing video…", color: .secondaryLabel)
        let prepared = await MediaPipeline.prepareVideo(at: videoURL)
        if prepared.didShrink {
            showStatus("Compressed to \(MediaPipeline.format(bytes: prepared.byteCount))"
                       + " (was \(MediaPipeline.format(bytes: prepared.originalByteCount)))",
                       color: .secondaryLabel)
        }

        let key = "point-photos/\(UUID().uuidString).\(prepared.url.pathExtension)"
        setUploadInProgress(true)
        do {
            try await MediaPipeline.uploadFile(
                at: prepared.url,
                key: key,
                onStart: { [weak self] task in self?.activeUpload = task },
                onProgress: { [weak self] fraction, sent, total in
                    Task { @MainActor in
                        self?.showStatus(
                            MediaPipeline.progressText(fraction: fraction, sent: sent, total: total),
                            color: .secondaryLabel)
                    }
                })
        } catch {
            setUploadInProgress(false)
            MediaPipeline.discardScratch(prepared.scratchURLs)
            showStatus(uploadFailureMessage(error), color: .systemRed)
            return
        }
        setUploadInProgress(false)

        let thumbnail = await Task.detached(priority: .userInitiated) { [url = prepared.url] in
            Self.videoThumbnail(from: url) ?? UIImage()
        }.value

        // Auto-save: create the point if needed, then attach this key.
        let saved = await ensurePointCreated(addingKey: key)
        guard saved else {
            // The bytes are in S3 but nothing references them — remove the
            // object rather than leave it orphaned in the bucket.
            await MediaPipeline.deleteOrphan(key: key)
            MediaPipeline.discardScratch(prepared.scratchURLs)
            return
        }

        MediaPipeline.discardScratch(prepared.scratchURLs)
        await MainActor.run {
            uploadedThumbs.append(thumbnail)
            refreshUploadedChips()
            setPendingMedia(image: nil, videoURL: nil)
            showStatus("Upload successful!", color: .systemGreen)
        }
    }

    // MARK: - Upload progress / cancellation

    private func setUploadInProgress(_ uploading: Bool) {
        cancelUploadButton.isHidden = !uploading
        uploadButton.isEnabled = !uploading
        if !uploading { activeUpload = nil }
    }

    @objc private func cancelUpload() {
        activeUpload?.cancel()
        activeUpload = nil
        cancelUploadButton.isHidden = true
        uploadButton.isEnabled = true
        showStatus("Upload cancelled.", color: .systemOrange)
    }

    /// Amplify reports a cancelled upload as an error; don't call that a failure.
    private func uploadFailureMessage(_ error: Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("cancel") { return "Upload cancelled." }
        return "Upload failed: \(error.localizedDescription)"
    }

    // MARK: - Helpers

    private func formatted(_ date: Date, mode: UIDatePicker.Mode) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
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

    /// Rebuild the thumbnail chips for items already uploaded.
    private func refreshUploadedChips() {
        uploadedChipsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for thumb in uploadedThumbs {
            let iv = UIImageView(image: thumb)
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.layer.cornerRadius = 6
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 48).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 48).isActive = true
            uploadedChipsStack.addArrangedSubview(iv)
        }
        let hasItems = !uploadedThumbs.isEmpty
        uploadedLabel.isHidden = !hasItems
        uploadedChipsStack.isHidden = !hasItems
    }
}

// MARK: - PHPickerViewControllerDelegate (library)

extension NewPointViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }

        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
                guard let url else { return }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".mp4")
                try? FileManager.default.copyItem(at: url, to: dest)
                let thumbnail = Self.videoThumbnail(from: dest) ?? UIImage()
                Task { @MainActor [weak self] in self?.setPendingMedia(image: thumbnail, videoURL: dest) }
            }
        } else if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                guard let img = obj as? UIImage else { return }
                Task { @MainActor [weak self] in self?.setPendingMedia(image: img, videoURL: nil) }
            }
        }
    }
}

// MARK: - UIImagePickerControllerDelegate (camera)

extension NewPointViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        dismiss(animated: true)
        if let videoURL = info[.mediaURL] as? URL {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            try? FileManager.default.copyItem(at: videoURL, to: dest)
            let thumbnail = Self.videoThumbnail(from: dest) ?? UIImage()
            setPendingMedia(image: thumbnail, videoURL: dest)
        } else if let img = info[.originalImage] as? UIImage {
            setPendingMedia(image: img, videoURL: nil)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss(animated: true) }
}
