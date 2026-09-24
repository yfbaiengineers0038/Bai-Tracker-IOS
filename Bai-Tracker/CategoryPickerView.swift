import UIKit

/// A dropdown for picking a point category.
///
/// Renders as a label + tappable button showing the current selection with its
/// color dot. Tapping opens an action sheet listing all categories plus an
/// "Add Category" action that prompts for a name + a color swatch.
///
/// Read the selection via `categoryName` (mirrors how callers used a
/// text field's `.text`).
final class CategoryPickerView: UIView {

    /// The currently selected category name, or nil if none.
    var categoryName: String? {
        get { selectedName }
        set { setSelected(newValue) }
    }

    private var selectedName: String?

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Category"
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabel
        return l
    }()

    private let dotView: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 6
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 12).isActive = true
        v.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return v
    }()

    private let valueLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 16)
        l.textColor = .label
        return l
    }()

    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    private let selectionButton = UIButton(type: .system)

    init() {
        super.init(frame: .zero)
        setup()
        setSelected(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let row = UIStackView(arrangedSubviews: [dotView, valueLabel, UIView(), chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        row.backgroundColor = .secondarySystemBackground
        row.layer.cornerRadius = 8

        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 14).isActive = true
        chevron.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, row])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Tap anywhere on the row opens the picker.
        selectionButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionButton)
        NSLayoutConstraint.activate([
            selectionButton.topAnchor.constraint(equalTo: row.topAnchor),
            selectionButton.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            selectionButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            selectionButton.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        selectionButton.addTarget(self, action: #selector(openPicker), for: .touchUpInside)

        // Refresh the list live when categories are added.
        CategoryStore.shared.onChange = { [weak self] in
            self?.refreshSelectedColor()
        }
    }

    private func setSelected(_ name: String?) {
        selectedName = name
        valueLabel.text = (name?.isEmpty ?? true) ? "Select category" : name
        refreshSelectedColor()
    }

    private func refreshSelectedColor() {
        dotView.backgroundColor = CategoryStore.shared.color(for: selectedName)
    }

    // MARK: - Dropdown

    @objc private func openPicker() {
        guard let vc = window?.rootViewController?.topMostViewController() else { return }
        let sheet = UIAlertController(title: "Category", message: nil, preferredStyle: .actionSheet)

        for def in CategoryStore.shared.all {
            sheet.addAction(UIAlertAction(title: def.name, style: .default) { [weak self] _ in
                self?.setSelected(def.name)
            })
        }
        sheet.addAction(UIAlertAction(title: "Add Category…", style: .default) { [weak self] _ in
            self?.presentAddCategory()
        })
        if selectedName != nil {
            sheet.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
                self?.setSelected(nil)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = selectionButton
        vc.present(sheet, animated: true)
    }

    private func presentAddCategory() {
        guard let vc = window?.rootViewController?.topMostViewController() else { return }
        let alert = UIAlertController(title: "New Category",
                                      message: "Enter a name and pick a color.",
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Category name"; $0.autocapitalizationType = .words }

        // Swatch picker embedded via a container vc is awkward in an alert;
        // instead present a dedicated modal for name + swatch selection.
        let name = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        alert.addAction(UIAlertAction(title: "Choose Color…", style: .default) { [weak self] _ in
            let entered = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self?.presentSwatchPicker(prefilledName: entered, on: vc)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        vc.present(alert, animated: true)
        _ = name // (name captured only to seed; flow handled in swatch picker)
    }

    private func presentSwatchPicker(prefilledName: String, on presenter: UIViewController) {
        let swatchVC = SwatchPickerViewController(prefilledName: prefilledName) { [weak self] name, color in
            CategoryStore.shared.add(name: name, color: color)
            self?.setSelected(name)
        }
        let nav = UINavigationController(rootViewController: swatchVC)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(nav, animated: true)
    }
}

// MARK: - Swatch picker VC

private final class SwatchPickerViewController: UIViewController {

    private let prefilledName: String
    private let onPick: (String, UIColor) -> Void
    private var selectedColor: UIColor = CategoryStore.palette[0]
    private let nameField = UITextField()

    init(prefilledName: String, onPick: @escaping (String, UIColor) -> Void) {
        self.prefilledName = prefilledName
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "New Category"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Cancel", style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Add", style: .done, target: self, action: #selector(add))

        nameField.placeholder = "Category name"
        nameField.text = prefilledName
        nameField.borderStyle = .roundedRect
        nameField.font = .systemFont(ofSize: 16)
        nameField.autocapitalizationType = .words
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let sectionLabel = UILabel()
        sectionLabel.text = "Color"
        sectionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sectionLabel.textColor = .secondaryLabel
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [nameField, sectionLabel, buildSwatchGrid()])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }

    private func buildSwatchGrid() -> UIView {
        let cols: CGFloat = 7
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        var rows: [UIStackView] = []
        var current = UIStackView()
        current.axis = .horizontal
        current.spacing = 12
        current.distribution = .fillEqually

        for (i, color) in CategoryStore.palette.enumerated() {
            let swatch = SwatchButton(color: color)
            if color == selectedColor { swatch.isSelected = true }
            swatch.tag = i
            swatch.addTarget(self, action: #selector(pickSwatch(_:)), for: .touchUpInside)
            current.addArrangedSubview(swatch)
            if (i + 1) % Int(cols) == 0 {
                rows.append(current)
                current = UIStackView()
                current.axis = .horizontal
                current.spacing = 12
                current.distribution = .fillEqually
            }
        }
        if current.arrangedSubviews.count > 0 { rows.append(current) }

        let grid = UIStackView(arrangedSubviews: rows)
        grid.axis = .vertical
        grid.spacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    @objc private func pickSwatch(_ sender: SwatchButton) {
        selectedColor = sender.color
        // Update selection ring on all swatches.
        view.subviews
            .flatMap { $0.subviews }
            .compactMap { $0 as? UIStackView }
            .flatMap { $0.subviews }
            .compactMap { $0 as? SwatchButton }
            .forEach { $0.isSelected = ($0 === sender) }
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func add() {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            nameField.layer.borderColor = UIColor.systemRed.cgColor
            nameField.layer.borderWidth = 1
            return
        }
        onPick(name, selectedColor)
        dismiss(animated: true)
    }
}

private final class SwatchButton: UIControl {
    let color: UIColor
    override var isSelected: Bool { didSet { update() } }

    init(color: UIColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 16
        layer.borderWidth = 0
        update()
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        backgroundColor = color
        layer.borderWidth = isSelected ? 3 : 0
        layer.borderColor = isSelected ? UIColor.label.cgColor : nil
        transform = isSelected ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
    }
}

// MARK: - Top-most VC helper

extension UIViewController {
    /// Walks presented controllers to find the one currently on top,
    /// so alerts/sheets present from the right place.
    func topMostViewController() -> UIViewController {
        if let presented = presentedViewController {
            return presented.topMostViewController()
        }
        if let nav = self as? UINavigationController, let visible = nav.visibleViewController {
            return visible.topMostViewController()
        }
        return self
    }
}
