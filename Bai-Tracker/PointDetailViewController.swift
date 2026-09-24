import UIKit
import PhotosUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import Amplify

// MARK: - PointDetailViewController

@MainActor
final class PointDetailViewController: UIViewController {

    weak var delegate: PointDetailDelegate?

    private var point: PointData
    private var loadedMedia: [MediaItem?]          // parallel to point.photos
    private var photoCollection: UICollectionView!

    // Media staged for upload (set by Photo/Video/Audio buttons, sent by Upload button)
    private var pendingImage: UIImage?
    private var pendingVideoURL: URL?
    private var pendingAudioURL: URL?

    /// The running S3 upload, so it can be cancelled mid-flight.
    private var activeUpload: StorageUploadFileTask?

    /// Appears only while an upload is in progress.
    private lazy var cancelUploadButton: UIButton = {
        let b = makeButton(title: "Cancel Upload", color: .systemGray,
                           action: #selector(cancelUpload))
        b.isHidden = true
        return b
    }()

    /// Live voice-memo recorder; non-nil only while recording.
    private var audioRecorder: AVAudioRecorder?
    /// Ticks the elapsed-time readout while recording.
    private var recordingTimer: Timer?

    /// Held as a property so recording can retitle it to "Stop".
    private lazy var audioButton = makeButton(
        title: "Audio", color: .appPurple, action: #selector(toggleAudioRecording))

    // MARK: - Fields

    private lazy var dateField        = LabeledField(label: "Date",        value: point.date)
    private lazy var timeField        = LabeledField(label: "Time",        value: point.time)
    private lazy var locationField    = LabeledField(label: "Name",        value: point.location)
    private lazy var descriptionField = LabeledField(label: "Description", value: point.description)
    private lazy var categoryField: CategoryPickerView = {
        let v = CategoryPickerView()
        v.categoryName = point.category
        return v
    }()
    private lazy var timezoneField: LabeledField = {
        // Timezone is captured at creation and shown read-only.
        let f = LabeledField(label: "Timezone", value: point.timezone)
        f.textField.isEnabled = false
        f.textField.textColor = .secondaryLabel
        return f
    }()

    // Comments are edited in-place here; the current list is sent on Finish.
    private var comments: [String]
    private let commentsStack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 6
        return s
    }()
    private let commentInput: UITextField = {
        let f = UITextField()
        f.placeholder = "Add a comment"
        f.borderStyle = .roundedRect
        f.font = .systemFont(ofSize: 15)
        return f
    }()

    private let newMediaPreview: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 8
        iv.backgroundColor = .secondarySystemBackground
        iv.isHidden = true
        iv.heightAnchor.constraint(equalToConstant: 180).isActive = true
        return iv
    }()

    private let newMediaVideoIcon: UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "play.circle.fill",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 40)))
        iv.tintColor = .white
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.isHidden = true
        return iv
    }()

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textAlignment = .center
        l.numberOfLines = 0
        l.isHidden = true
        return l
    }()

    // MARK: - Init

    init(point: PointData) {
        self.point = point
        self.loadedMedia = Array(repeating: nil, count: point.photos.count)
        self.comments = point.comments
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Point"
        buildLayout()
        Task { await loadMedia() }
    }

    // MARK: - Layout

    private func buildLayout() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 90, height: 90)
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

        photoCollection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        photoCollection.backgroundColor = .clear
        photoCollection.showsHorizontalScrollIndicator = false
        photoCollection.dataSource = self
        photoCollection.delegate   = self
        photoCollection.register(PhotoThumbCell.self, forCellWithReuseIdentifier: PhotoThumbCell.reuseID)
        photoCollection.heightAnchor.constraint(equalToConstant: 100).isActive = true
        photoCollection.isHidden = point.photos.isEmpty

        // Overlay play icon on the staged-media preview
        newMediaPreview.addSubview(newMediaVideoIcon)
        NSLayoutConstraint.activate([
            newMediaVideoIcon.centerXAnchor.constraint(equalTo: newMediaPreview.centerXAnchor),
            newMediaVideoIcon.centerYAnchor.constraint(equalTo: newMediaPreview.centerYAnchor)
        ])

        let photoBtn  = makeButton(title: "Photo",  color: .systemBlue,  action: #selector(addPhoto))
        let videoBtn  = makeButton(title: "Video",  color: .systemBlue,  action: #selector(addVideo))
        let uploadBtn = makeButton(title: "Finish", color: .appPurple,   action: #selector(uploadAndSave))
        let deleteBtn = makeButton(title: "Delete", color: .systemRed,   action: #selector(deletePoint))
        let cancelBtn = makeButton(title: "Cancel", color: .systemGray,  action: #selector(cancel))

        // Audio records a voice memo; saving now lives on Finish, which
        // commits the edits and closes the sheet.
        let mediaRow  = hStack([photoBtn, videoBtn, uploadBtn])
        let actionRow = hStack([audioButton, deleteBtn, cancelBtn])

        let addCommentBtn = makeButton(title: "Add", color: .systemBlue, action: #selector(addComment))
        addCommentBtn.setContentHuggingPriority(.required, for: .horizontal)
        let commentInputRow = UIStackView(arrangedSubviews: [commentInput, addCommentBtn])
        commentInputRow.axis = .horizontal
        commentInputRow.spacing = 8
        refreshComments()

        let commentsHeader = UILabel()
        commentsHeader.text = "Comments"
        commentsHeader.font = .systemFont(ofSize: 12, weight: .medium)
        commentsHeader.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [
            dateField.container, timeField.container,
            locationField.container, descriptionField.container,
            categoryField, timezoneField.container,
            commentsHeader, commentsStack, commentInputRow,
            photoCollection, newMediaPreview,
            mediaRow, statusLabel, cancelUploadButton, actionRow
        ])
        stack.axis = .vertical
        stack.spacing = 14
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
            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -40)
        ])
    }

    // MARK: - Load existing media

    @MainActor
    private func loadMedia() async {
        guard !point.photos.isEmpty else { return }
        await withTaskGroup(of: (Int, MediaItem?).self) { group in
            for (idx, key) in point.photos.enumerated() {
                group.addTask { (idx, await Self.fetchMedia(key: key)) }
            }
            for await (idx, item) in group {
                loadedMedia[idx] = item   // safe: always on MainActor
                photoCollection.reloadItems(at: [IndexPath(item: idx, section: 0)])
            }
        }
        photoCollection.isHidden = false
        photoCollection.reloadData()
    }

    nonisolated static func fetchMedia(key: String) async -> MediaItem? {
        let isVideo = key.hasSuffix(".mp4") || key.hasSuffix(".mov")
        let isAudio = key.hasSuffix(".m4a")
        do {
            let url = try await Amplify.Storage.getURL(path: .fromString(key))
            if isAudio {
                // Voice memos have no frame to thumbnail, but AVPlayer plays
                // them through the same tap-to-play path as video.
                return .video(thumbnail: NewPointViewController.audioThumbnail(), url: url)
            }
            if isVideo {
                let thumbnail = await Task.detached(priority: .userInitiated) {
                    Self.videoThumbnail(from: url) ?? UIImage()
                }.value
                return .video(thumbnail: thumbnail, url: url)
            } else {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let img = UIImage(data: data) else { return nil }
                return .photo(img)
            }
        } catch {
            return nil
        }
    }

    nonisolated static func videoThumbnail(from url: URL) -> UIImage? {
        let asset     = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Photo button (camera or library)

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

    // MARK: - Video button (camera or library)

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

    private func recordVideo() {
        // The camera in video mode requires BOTH camera and microphone access,
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
            // Defer so presentation never collides with the action sheet's dismissal.
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
        newMediaPreview.image    = image
        newMediaPreview.isHidden = (image == nil)
        newMediaVideoIcon.isHidden = (videoURL == nil)
        // A waveform symbol would be cropped by the photo/video fill mode.
        newMediaPreview.contentMode = (audioURL == nil) ? .scaleAspectFill : .scaleAspectFit
        // Auto-upload as soon as media is captured/picked — no Finish tap needed.
        if image != nil {
            uploadMedia()
        }
    }

    // MARK: - Upload button

    /// Commits the point: uploads anything still pending (including a memo the
    /// user just recorded), then saves the edited fields and closes the sheet.
    @objc private func uploadAndSave() {
        // A recording still running would otherwise be lost on dismiss.
        if audioRecorder?.isRecording == true { stopRecording() }

        guard pendingImage != nil || pendingVideoURL != nil || pendingAudioURL != nil else {
            save()
            return
        }

        Task {
            await uploadPendingMedia()
            // Only close once the media is safely attached.
            if pendingImage == nil && pendingVideoURL == nil && pendingAudioURL == nil {
                save()
            }
        }
    }

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
        Task { await uploadPendingMedia() }
    }

    private func uploadPhoto(data: Data, thumbnail: UIImage) async {
        let key = "point-photos/\(point.id)-\(UUID().uuidString).jpg"
        showStatus("Uploading photo…", color: .secondaryLabel)
        do {
            _ = try await Amplify.Storage.uploadData(path: .fromString(key), data: data).value
        } catch {
            showStatus("S3 upload failed: \(String(reflecting: error))", color: .systemRed)
            return
        }
        if await !persistKey(key, newItem: .photo(thumbnail)) {
            await MediaPipeline.deleteOrphan(key: key)
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

        let key = "point-photos/\(point.id)-\(UUID().uuidString).\(prepared.url.pathExtension)"
        guard await performUpload(of: prepared.url, key: key, scratch: prepared.scratchURLs) else {
            return
        }

        let thumbnail = await Task.detached(priority: .userInitiated) { [url = prepared.url] in
            Self.videoThumbnail(from: url) ?? UIImage()
        }.value
        let playURL = (try? await Amplify.Storage.getURL(path: .fromString(key))) ?? prepared.url

        if await !persistKey(key, newItem: .video(thumbnail: thumbnail, url: playURL)) {
            await MediaPipeline.deleteOrphan(key: key)
        }
        MediaPipeline.discardScratch(prepared.scratchURLs)
    }

    private func uploadAudio(_ audioURL: URL) async {
        let key = "point-photos/\(point.id)-\(UUID().uuidString).m4a"
        guard await performUpload(of: audioURL, key: key, scratch: [audioURL]) else { return }

        let playURL = (try? await Amplify.Storage.getURL(path: .fromString(key))) ?? audioURL
        if await !persistKey(key, newItem: .video(thumbnail: NewPointViewController.audioThumbnail(),
                                                  url: playURL)) {
            await MediaPipeline.deleteOrphan(key: key)
        }
        MediaPipeline.discardScratch([audioURL])
    }

    /// Uploads with live progress and cancellation. Returns false if it
    /// failed or was cancelled (scratch files are cleaned up in that case).
    private func performUpload(of url: URL, key: String, scratch: [URL]) async -> Bool {
        setUploadInProgress(true)
        do {
            try await MediaPipeline.uploadFile(
                at: url,
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
            MediaPipeline.discardScratch(scratch)
            let text = String(describing: error).lowercased()
            showStatus(text.contains("cancel")
                       ? "Upload cancelled."
                       : "Upload failed: \(error.localizedDescription)",
                       color: text.contains("cancel") ? .systemOrange : .systemRed)
            return false
        }
        setUploadInProgress(false)
        return true
    }

    // MARK: - Upload progress / cancellation

    private func setUploadInProgress(_ uploading: Bool) {
        cancelUploadButton.isHidden = !uploading
        if !uploading { activeUpload = nil }
    }

    @objc private func cancelUpload() {
        activeUpload?.cancel()
        activeUpload = nil
        cancelUploadButton.isHidden = true
        showStatus("Upload cancelled.", color: .systemOrange)
    }

    /// Attaches `key` to the point. Returns false if the metadata write
    /// failed, meaning the uploaded object is orphaned and should be removed.
    @discardableResult
    private func persistKey(_ key: String, newItem: MediaItem) async -> Bool {
        var updatedPhotos = point.photos
        updatedPhotos.append(key)
        do {
            try await updatePhotosOnBackend(updatedPhotos)
        } catch {
            showStatus("Uploaded but metadata save failed: \(String(reflecting: error))", color: .systemOrange)
            return false
        }
        point.photos = updatedPhotos
        loadedMedia.append(newItem)
        pendingImage = nil; pendingVideoURL = nil; pendingAudioURL = nil
        newMediaPreview.isHidden = true
        newMediaVideoIcon.isHidden = true
        photoCollection.isHidden = false
        photoCollection.reloadData()
        delegate?.pointDetailDidUpdate(point)
        showStatus("Upload successful!", color: .systemGreen)
        return true
    }

    private func updatePhotosOnBackend(_ photos: [String]) async throws {
        let mutation = """
        mutation UpdatePoint($input: UpdatePointInput!) {
          updatePoint(input: $input) { id photos }
        }
        """
        struct P: Decodable { let id: String; let photos: [String]? }
        struct R: Decodable { let updatePoint: P }
        let vars: [String: Any] = ["input": ["id": point.id, "photos": photos]]
        let req = GraphQLRequest<R>(document: mutation, variables: vars, responseType: R.self)
        let result = try await Amplify.API.mutate(request: req)
        if case .failure(let responseError) = result {
            throw NSError(domain: "GraphQL", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: String(reflecting: responseError)])
        }
    }

    private func deleteMedia(at index: Int) {
        let key = point.photos[index]
        Task {
            do {
                _ = try await Amplify.Storage.remove(path: .fromString(key))
                var updatedPhotos = point.photos
                updatedPhotos.remove(at: index)
                try await updatePhotosOnBackend(updatedPhotos)
                point.photos = updatedPhotos
                loadedMedia.remove(at: index)
                photoCollection.reloadData()
                photoCollection.isHidden = point.photos.isEmpty
                delegate?.pointDetailDidUpdate(point)
            } catch {
                showStatus("Delete failed: \(error.localizedDescription)", color: .systemRed)
            }
        }
    }

    // MARK: - Save / Delete point / Cancel

    private func save() {
        let mutation = """
        mutation UpdatePoint($input: UpdatePointInput!) {
          updatePoint(input: $input) {
            id date time location description lat lng photos timezone comments category
          }
        }
        """
        struct U: Decodable {
            let id: String; let date: String; let time: String?
            let location: String?; let description: String?
            let lat: Double; let lng: Double; let photos: [String]?
            let timezone: String?; let comments: [String]?; let category: String?
        }
        struct R: Decodable { let updatePoint: U }

        let vars: [String: Any] = ["input": [
            "id":          point.id,
            "date":        dateField.textField.text ?? point.date,
            "time":        timeField.textField.text ?? "",
            "location":    locationField.textField.text ?? "",
            "description": descriptionField.textField.text ?? "",
            "category":    categoryField.categoryName ?? "",
            "comments":    comments,
            "photos":      point.photos
        ]]
        let req = GraphQLRequest<R>(document: mutation, variables: vars, responseType: R.self)
        Task {
            do {
                let result = try await Amplify.API.mutate(request: req)
                switch result {
                case .success(let data):
                    let u = data.updatePoint
                    var updated = point
                    updated.date = u.date; updated.time = u.time
                    updated.location = u.location; updated.description = u.description
                    updated.photos = u.photos ?? point.photos
                    updated.timezone = u.timezone ?? point.timezone
                    updated.comments = u.comments ?? comments
                    updated.category = u.category
                    self.point = updated
                    self.comments = updated.comments
                    delegate?.pointDetailDidUpdate(updated)
                    dismiss(animated: true)
                case .failure(let e):
                    showStatus("Update failed: \(String(reflecting: e))", color: .systemRed)
                }
            } catch {
                showStatus("Update failed: \(error.localizedDescription)", color: .systemRed)
            }
        }
    }

    @objc private func deletePoint() {
        let alert = UIAlertController(title: "Delete Point", message: "This cannot be undone.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in self?.performDelete() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func performDelete() {
        let mutation = "mutation DeletePoint($input: DeletePointInput!) { deletePoint(input: $input) { id } }"
        struct R: Decodable { struct D: Decodable { let id: String }; let deletePoint: D }
        let req = GraphQLRequest<R>(document: mutation, variables: ["input": ["id": point.id]], responseType: R.self)
        Task {
            if case .success = (try? await Amplify.API.mutate(request: req)) ?? .failure(.unknown("", "", nil)) {
                delegate?.pointDetailDidDelete(id: point.id)
                dismiss(animated: true)
            }
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
        setPendingMedia(image: NewPointViewController.audioThumbnail(),
                        videoURL: nil, audioURL: url)
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
        c?.baseBackgroundColor = isRecording ? .systemRed : .appPurple
        audioButton.configuration = c
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Comments

    @objc private func addComment() {
        let text = commentInput.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        comments.append(text)
        commentInput.text = ""
        refreshComments()
    }

    /// Rebuilds the comment rows from `comments`. Each row is the text plus a
    /// delete button; edits are persisted when the user taps Finish.
    private func refreshComments() {
        commentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (idx, comment) in comments.enumerated() {
            let label = UILabel()
            label.text = comment
            label.font = .systemFont(ofSize: 15)
            label.numberOfLines = 0
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let deleteBtn = UIButton(type: .system)
            deleteBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            deleteBtn.tintColor = .tertiaryLabel
            deleteBtn.tag = idx
            deleteBtn.addTarget(self, action: #selector(deleteComment(_:)), for: .touchUpInside)
            deleteBtn.setContentHuggingPriority(.required, for: .horizontal)

            let row = UIStackView(arrangedSubviews: [label, deleteBtn])
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .center
            commentsStack.addArrangedSubview(row)
        }
        commentsStack.isHidden = comments.isEmpty
    }

    @objc private func deleteComment(_ sender: UIButton) {
        guard comments.indices.contains(sender.tag) else { return }
        comments.remove(at: sender.tag)
        refreshComments()
    }

    // MARK: - Helpers

    private func showStatus(_ msg: String, color: UIColor) {
        statusLabel.text = msg; statusLabel.textColor = color; statusLabel.isHidden = false
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
}

// MARK: - PHPickerViewControllerDelegate (library)

extension PointDetailViewController: PHPickerViewControllerDelegate {
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

extension PointDetailViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
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

// MARK: - UICollectionViewDataSource / Delegate

extension PointDetailViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        point.photos.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PhotoThumbCell.reuseID, for: indexPath) as! PhotoThumbCell
        let item = loadedMedia[indexPath.item]
        cell.configure(media: item) { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(title: "Delete?", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
                self.deleteMedia(at: indexPath.item)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self.present(alert, animated: true)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let items = loadedMedia.compactMap { $0 }
        let carouselIndex = loadedMedia[..<indexPath.item].filter { $0 != nil }.count
        guard !items.isEmpty else { return }

        // If it's a video, play directly
        if let videoURL = items[carouselIndex].videoURL {
            let player = AVPlayer(url: videoURL)
            let playerVC = AVPlayerViewController()
            playerVC.player = player
            present(playerVC, animated: true) { player.play() }
        } else {
            let photos = items.compactMap { item -> UIImage? in
                if case .photo(let img) = item { return img }
                return item.thumbnail
            }
            let carousel = PhotoCarouselViewController(images: photos, startIndex: carouselIndex)
            carousel.modalPresentationStyle = .overFullScreen
            carousel.modalTransitionStyle   = .crossDissolve
            present(carousel, animated: true)
        }
    }
}

// MARK: - PhotoThumbCell

final class PhotoThumbCell: UICollectionViewCell {
    static let reuseID = "PhotoThumbCell"

    private let imageView  = UIImageView()
    private let deleteBtn  = UIButton(type: .system)
    private let spinner    = UIActivityIndicatorView(style: .medium)
    private let playIcon   = UIImageView()
    private var onDelete: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 6
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        let playImg = UIImage(systemName: "play.circle.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 28))
        playIcon.image = playImg
        playIcon.tintColor = .white
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playIcon.isHidden = true
        contentView.addSubview(playIcon)

        let xImg = UIImage(systemName: "xmark.circle.fill",
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold))
        deleteBtn.setImage(xImg, for: .normal)
        deleteBtn.tintColor = .white
        deleteBtn.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        deleteBtn.layer.cornerRadius = 11
        deleteBtn.clipsToBounds = true
        deleteBtn.translatesAutoresizingMaskIntoConstraints = false
        deleteBtn.addTarget(self, action: #selector(tappedDelete), for: .touchUpInside)
        contentView.addSubview(deleteBtn)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            playIcon.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            playIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            deleteBtn.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            deleteBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            deleteBtn.widthAnchor.constraint(equalToConstant: 22),
            deleteBtn.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(media: MediaItem?, onDelete: @escaping () -> Void) {
        self.onDelete = onDelete
        if let item = media {
            imageView.image = item.thumbnail
            playIcon.isHidden = !item.isVideo
            spinner.stopAnimating()
        } else {
            imageView.image = nil
            playIcon.isHidden = true
            spinner.startAnimating()
        }
    }

    @objc private func tappedDelete() { onDelete?() }
}

// MARK: - LabeledField

final class LabeledField {
    let container: UIStackView
    let textField: UITextField

    init(label: String, value: String?) {
        let lbl = UILabel()
        lbl.text = label
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = .secondaryLabel

        let tf = UITextField()
        tf.text = value
        tf.borderStyle = .roundedRect
        tf.font = .systemFont(ofSize: 16)
        tf.placeholder = label
        self.textField = tf

        let stack = UIStackView(arrangedSubviews: [lbl, tf])
        stack.axis = .vertical
        stack.spacing = 4
        self.container = stack
    }
}
