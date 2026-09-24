import UIKit

/// Second step of creating a project: search Google Places for where the
/// project is and report the picked location back via `onPick`.
///
/// Pushed onto the project picker's navigation stack by
/// `ProjectPickerViewController`.
final class PlacePickerViewController: UIViewController {

    /// Shown in the prompt so the user knows which project they're placing.
    var projectName: String?

    /// Biases predictions toward the map area the user came from, if known.
    var bias: (latitude: Double, longitude: Double)?

    /// Called on the main actor with the place the user picked.
    var onPick: ((PlaceLocation) -> Void)?

    private let searchBar = UISearchBar()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let statusLabel = UILabel()
    private let service = PlacesService()

    private var suggestions: [PlaceSuggestion] = []

    /// The in-flight autocomplete, cancelled whenever the query changes so
    /// stale results can't overwrite newer ones.
    private var searchTask: Task<Void, Never>?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Project Location"

        setupLayout()
        showStatus("Search for where this project is located.")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        searchBar.becomeFirstResponder()
    }

    // MARK: - Layout

    private func setupLayout() {
        searchBar.placeholder = "Search address or place"
        searchBar.autocapitalizationType = .words
        searchBar.autocorrectionType = .no
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        if let projectName {
            searchBar.accessibilityLabel = "Location for \(projectName)"
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SuggestionCell")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchBar)
        view.addSubview(tableView)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusLabel.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }

    // MARK: - Search

    /// Debounces typing, then replaces the suggestion list.
    private func search(_ query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            tableView.reloadData()
            showStatus("Search for where this project is located.")
            return
        }

        searchTask = Task { [weak self] in
            // Let the user finish typing before spending a request.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }

            do {
                let results = try await service.autocomplete(trimmed, near: bias)
                guard !Task.isCancelled else { return }
                suggestions = results
                tableView.reloadData()
                if results.isEmpty {
                    showStatus("No matches for \"\(trimmed)\".")
                } else {
                    statusLabel.isHidden = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                suggestions = []
                tableView.reloadData()
                showStatus(error.localizedDescription)
            }
        }
    }

    /// Resolves the tapped prediction to coordinates and hands it back.
    private func pick(_ suggestion: PlaceSuggestion) {
        searchTask?.cancel()
        searchBar.resignFirstResponder()
        showStatus("Locating \"\(suggestion.primaryText)\"…")

        Task { [weak self] in
            guard let self else { return }
            do {
                var place = try await service.details(placeID: suggestion.placeID)
                // Predictions occasionally carry a fuller label than the
                // details response, so prefer the row the user actually tapped.
                if place.name.isEmpty {
                    place = PlaceLocation(name: suggestion.primaryText,
                                          address: place.address,
                                          latitude: place.latitude,
                                          longitude: place.longitude)
                }
                onPick?(place)
            } catch {
                showStatus(error.localizedDescription)
            }
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }
}

// MARK: - Search bar

extension PlacePickerViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        search(searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

// MARK: - Table

extension PlacePickerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        suggestions.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SuggestionCell", for: indexPath)
        let suggestion = suggestions[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = suggestion.primaryText
        content.secondaryText = suggestion.secondaryText
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        pick(suggestions[indexPath.row])
    }
}
