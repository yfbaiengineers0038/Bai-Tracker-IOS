import UIKit

protocol PointListSheetDelegate: AnyObject {
    func sheet(_ sheet: PointListBottomSheet, didTapLocate point: PointData)
    func sheet(_ sheet: PointListBottomSheet, didTapEdit point: PointData)
    func sheet(_ sheet: PointListBottomSheet, didSelectRow point: PointData)
}

/// Expandable bottom sheet listing all points sorted most-recent-first.
/// Collapsed it shows a handle + title; tap/drag up to expand into a list.
final class PointListBottomSheet: UIView {

    weak var delegate: PointListSheetDelegate?

    private var points: [PointData] = []

    // MARK: - Detents

    private let collapsedHeight: CGFloat = 70
    private var expandedHeight: CGFloat {
        UIScreen.main.bounds.height * 0.65
    }
    private var isExpanded = false

    // MARK: - UI

    private let handleView: UIView = {
        let v = UIView()
        v.backgroundColor = .separator
        v.layer.cornerRadius = 2.5
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 36).isActive = true
        v.heightAnchor.constraint(equalToConstant: 5).isActive = true
        return v
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 16, weight: .semibold)
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let headerStack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.alignment = .center
        s.spacing = 6
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .plain)
        t.translatesAutoresizingMaskIntoConstraints = false
        t.rowHeight = 64
        t.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        return t
    }()

    private var heightConstraint: NSLayoutConstraint!

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setup() {
        backgroundColor = .systemBackground
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: -2)
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 8
        layer.cornerRadius = 16
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clipsToBounds = true

        headerStack.addArrangedSubview(handleView)
        headerStack.addArrangedSubview(titleLabel)

        addSubview(headerStack)
        addSubview(tableView)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(PointCell.self, forCellReuseIdentifier: PointCell.reuseID)

        heightConstraint = heightAnchor.constraint(equalToConstant: collapsedHeight)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            tableView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),

            heightConstraint
        ])

        // Tap the header / handle to toggle.
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggle))
        headerStack.addGestureRecognizer(tap)

        // Drag to expand/collapse.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    // MARK: - Public API

    func update(_ points: [PointData]) {
        self.points = points
        titleLabel.text = points.isEmpty ? "All Points" : "All Points (\(points.count))"
        tableView.reloadData()
    }

    /// Collapse the sheet (e.g. after locating a point so the map is visible).
    func collapse() {
        guard isExpanded else { return }
        setExpanded(false, animated: true)
    }

    // MARK: - Expand / collapse

    @objc private func toggle() {
        setExpanded(!isExpanded, animated: true)
    }

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
        let work = { self.heightConstraint.constant = expanded ? self.expandedHeight : self.collapsedHeight
            self.superview?.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0,
                           usingSpringWithDamping: 0.85, initialSpringVelocity: 0.5,
                           options: [], animations: work)
        } else {
            work()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self).y // negative = drag up
        switch gesture.state {
        case .changed:
            // Drag the height down with the finger, clamped to the detents.
            let target = heightConstraint.constant - translation
            heightConstraint.constant = min(max(target, collapsedHeight), expandedHeight)
            gesture.setTranslation(.zero, in: self)
            isExpanded = heightConstraint.constant > (collapsedHeight + expandedHeight) / 2
        case .ended, .cancelled:
            // Snap to whichever detent is closer.
            let midpoint = (collapsedHeight + expandedHeight) / 2
            setExpanded(heightConstraint.constant > midpoint, animated: true)
        default: break
        }
    }
}

// MARK: - UITableViewDataSource

extension PointListBottomSheet: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        points.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: PointCell.reuseID, for: indexPath) as! PointCell
        let point = points[indexPath.row]
        cell.configure(point: point) { [weak self] in
            guard let self, indexPath.row < self.points.count else { return }
            self.delegate?.sheet(self, didTapLocate: self.points[indexPath.row])
        } onEdit: { [weak self] in
            guard let self, indexPath.row < self.points.count else { return }
            self.delegate?.sheet(self, didTapEdit: self.points[indexPath.row])
        }
        return cell
    }
}

// MARK: - UITableViewDelegate

extension PointListBottomSheet: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < points.count else { return }
        delegate?.sheet(self, didSelectRow: points[indexPath.row])
    }
}

// MARK: - Cell

private final class PointCell: UITableViewCell {

    static let reuseID = "PointCell"

    private let dotView: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 7
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 14).isActive = true
        v.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return v
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 16, weight: .medium)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let locateButton = UIButton(type: .system)
    private let editButton = UIButton(type: .system)

    private var onLocate: (() -> Void)?
    private var onEdit: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        configureIcon(locateButton, systemImage: "location.fill", tint: .appPurple)
        configureIcon(editButton, systemImage: "pencil", tint: .label)
        locateButton.addTarget(self, action: #selector(tapLocate), for: .touchUpInside)
        editButton.addTarget(self, action: #selector(tapEdit), for: .touchUpInside)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = UIStackView(arrangedSubviews: [locateButton, editButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 4
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(dotView)
        contentView.addSubview(textStack)
        contentView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            dotView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -8),

            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(point: PointData, onLocate: @escaping () -> Void, onEdit: @escaping () -> Void) {
        titleLabel.text = point.location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? point.location : "No name"
        dotView.backgroundColor = CategoryColors.color(for: point.category)

        var bits = [point.date]
        if let t = point.time, !t.isEmpty { bits.append(t) }
        if let desc = point.description, !desc.isEmpty { bits.append(desc) }
        subtitleLabel.text = bits.joined(separator: " • ")

        self.onLocate = onLocate
        self.onEdit = onEdit
    }

    private func configureIcon(_ button: UIButton, systemImage: String, tint: UIColor) {
        let img = UIImage(systemName: systemImage,
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        button.setImage(img, for: .normal)
        button.tintColor = tint
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    @objc private func tapLocate() { onLocate?() }
    @objc private func tapEdit()   { onEdit?() }
}
