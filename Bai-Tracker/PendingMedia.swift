import UIKit

/// One attachment captured but not yet uploaded.
///
/// Media is staged rather than sent on capture so a crew can shoot a whole
/// sequence — several photos, a clip, a memo — and push it in one batch when
/// they tap Finish, instead of waiting out an upload between every shot.
struct PendingMedia {
    enum Kind {
        case photo(UIImage)
        case video(URL)
        case audio(URL)
    }

    /// Identifies the item across a batch upload, so items that uploaded can
    /// be removed from the queue without disturbing anything captured while
    /// that upload was still running.
    let id = UUID()

    let kind: Kind
    /// What the tray shows; for audio this is a stand-in symbol.
    let thumbnail: UIImage

    var isPlayable: Bool {
        switch kind {
        case .photo: return false
        case .video, .audio: return true
        }
    }

    /// The scratch file backing this item, if any. Deleted once the item is
    /// uploaded, removed from the tray, or the screen is cancelled.
    var fileURL: URL? {
        switch kind {
        case .photo: return nil
        case .video(let url), .audio(let url): return url
        }
    }
}

/// Horizontal strip of staged attachments, each removable, with a count header.
///
/// Shared by the new-point and point-detail screens so both stage media the
/// same way.
final class PendingMediaTray: UIView {

    /// Index of the item whose ✕ was tapped.
    var onRemove: ((Int) -> Void)?

    private let header: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabel
        return l
    }()

    private let row: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 8
        s.alignment = .center
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let scroll: UIScrollView = {
        let s = UIScrollView()
        s.showsHorizontalScrollIndicator = false
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private static let thumbSide: CGFloat = 68

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        scroll.addSubview(row)

        let column = UIStackView(arrangedSubviews: [header, scroll])
        column.axis = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),

            row.topAnchor.constraint(equalTo: scroll.topAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.heightAnchor),

            scroll.heightAnchor.constraint(equalToConstant: Self.thumbSide)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the strip. Hides itself when nothing is staged.
    func update(with items: [PendingMedia]) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            row.addArrangedSubview(makeThumb(for: item, at: index))
        }
        header.text = items.count == 1
            ? "1 item ready to upload"
            : "\(items.count) items ready to upload"
        isHidden = items.isEmpty
    }

    private func makeThumb(for item: PendingMedia, at index: Int) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let image = UIImageView(image: item.thumbnail)
        // A waveform symbol would be cropped by the photo/video fill mode.
        image.contentMode = item.isPlayable && item.fileURL?.pathExtension == "m4a"
            ? .scaleAspectFit
            : .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerRadius = 6
        image.backgroundColor = .secondarySystemBackground
        image.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(image)

        let badge = UIImageView(image: UIImage(
            systemName: "play.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)))
        badge.tintColor = .white
        badge.isHidden = !item.isPlayable
        badge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badge)

        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: "xmark.circle.fill",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)),
                        for: .normal)
        remove.tintColor = .white
        remove.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        remove.layer.cornerRadius = 10
        remove.clipsToBounds = true
        remove.tag = index
        remove.addTarget(self, action: #selector(tappedRemove(_:)), for: .touchUpInside)
        remove.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(remove)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.thumbSide),
            container.heightAnchor.constraint(equalToConstant: Self.thumbSide),

            image.topAnchor.constraint(equalTo: container.topAnchor),
            image.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            image.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            badge.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            remove.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            remove.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            remove.widthAnchor.constraint(equalToConstant: 20),
            remove.heightAnchor.constraint(equalToConstant: 20)
        ])

        return container
    }

    @objc private func tappedRemove(_ sender: UIButton) {
        onRemove?(sender.tag)
    }
}
