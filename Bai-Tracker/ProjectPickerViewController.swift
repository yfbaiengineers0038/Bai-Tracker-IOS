import UIKit
import Amplify

/// Lists backend `Project`s and lets the user pick one. Shown as a page sheet
/// both as a post-login gate (when no project is selected) and from the map's
/// "switch project" button.
///
/// On selection: persists via `ProjectStore.shared.setCurrent(...)` and
/// dismisses. If presented as a gate, the host then proceeds to the map.
final class ProjectPickerViewController: UIViewController {

    /// Set to true when this picker is the gate before entering the map.
    /// When gating, selection dismisses the picker and presents the map;
    /// when switching, the map already exists and reacts via `ProjectStore.onChange`.
    var isGate: Bool = false

    /// The map camera to center a newly-created project on (set by the map
    /// screen when presenting this picker). Falls back to the default area.
    var initialCamera: (lat: Double, lng: Double, zoom: Double)?

    private var projects: [Project] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let statusLabel = UILabel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Select Project"

        // When used as a switch (not a gate), allow cancelling.
        if !isGate {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "Cancel", style: .plain, target: self, action: #selector(cancel))
        }

        // New Project button, top-right.
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "New Project", style: .done, target: self, action: #selector(newProjectTapped))

        setupLayout()
        Task { await loadProjects() }
    }

    // MARK: - Layout

    private func setupLayout() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectCell")

        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isHidden = true

        view.addSubview(tableView)
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }

    // MARK: - Load

    private func loadProjects() async {
        showStatus("Loading projects…")
        let query = """
        query ListProjects {
          listProjects {
            items { id name lat lng zoom }
          }
        }
        """
        struct Item: Decodable {
            let id: String; let name: String
            let lat: Double; let lng: Double; let zoom: Double?
        }
        struct ListResult: Decodable { let items: [Item] }
        struct ResponseData: Decodable { let listProjects: ListResult }
        let request = GraphQLRequest<ResponseData>(document: query, variables: nil, responseType: ResponseData.self)

        do {
            let result = try await Amplify.API.query(request: request)
            guard case .success(let data) = result else {
                await MainActor.run { showStatus("Couldn't load projects.") }
                return
            }
            let items = data.listProjects.items
            await MainActor.run {
                self.projects = items.map {
                    Project(id: $0.id, name: $0.name, lat: $0.lat, lng: $0.lng, zoom: $0.zoom ?? 14)
                }
                if self.projects.isEmpty {
                    self.showStatus("No projects available yet.")
                } else {
                    self.statusLabel.isHidden = true
                    self.tableView.reloadData()
                }
            }
        } catch {
            await MainActor.run { self.showStatus("Failed: \(error.localizedDescription)") }
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }

    @objc private func cancel() { dismiss(animated: true) }

    // MARK: - New Project

    @objc private func newProjectTapped() {
        let alert = UIAlertController(title: "New Project",
                                      message: "Enter a name for the project.",
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Project name"; $0.autocapitalizationType = .words }
        alert.addAction(UIAlertAction(title: "Next", style: .default) { [weak self] _ in
            let name = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !name.isEmpty else { return }
            self.chooseLocation(forProjectNamed: name)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Second step: ask where the project is, searching Google Places.
    private func chooseLocation(forProjectNamed name: String) {
        let placePicker = PlacePickerViewController()
        placePicker.projectName = name
        // Rank places near where the user is looking on the map first.
        placePicker.bias = initialCamera.map { (latitude: $0.lat, longitude: $0.lng) }
        placePicker.onPick = { [weak self] place in
            guard let self else { return }
            navigationController?.popToViewController(self, animated: true)
            Task { await self.createProject(named: name, at: place) }
        }
        navigationController?.pushViewController(placePicker, animated: true)
    }

    /// Creates a project centered on the place the user picked, then switches
    /// to it.
    private func createProject(named name: String, at place: PlaceLocation) async {
        let lat = place.latitude
        let lng = place.longitude
        // Neighborhood-level zoom, close enough to start dropping points.
        let zoom = 14.0

        showStatus("Creating project…")
        let mutation = """
        mutation CreateProject($input: CreateProjectInput!) {
          createProject(input: $input) { id name lat lng zoom }
        }
        """
        struct CreatedProject: Decodable {
            let id: String; let name: String
            let lat: Double; let lng: Double; let zoom: Double?
        }
        struct ResponseData: Decodable { let createProject: CreatedProject }
        let vars: [String: Any] = ["input": [
            "name": name, "lat": lat, "lng": lng, "zoom": zoom
        ]]
        let request = GraphQLRequest<ResponseData>(
            document: mutation, variables: vars, responseType: ResponseData.self)

        do {
            let result = try await Amplify.API.mutate(request: request)
            guard case .success(let data) = result else {
                await MainActor.run { showStatus("Couldn't create project.") }
                return
            }
            let c = data.createProject
            let project = Project(id: c.id, name: c.name, lat: c.lat, lng: c.lng, zoom: c.zoom ?? zoom)
            await MainActor.run { select(project) }
        } catch {
            await MainActor.run { showStatus("Failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Delete

    /// Confirmation, then cascade-deletes the project: its points' S3 media,
    /// the points themselves, and finally the project record.
    private func confirmDelete(at indexPath: IndexPath) {
        guard indexPath.row < projects.count else { return }
        let project = projects[indexPath.row]

        let alert = UIAlertController(
            title: "Delete Project",
            message: "Delete \"\(project.name)\" and ALL of its points and photos/videos? This cannot be undone.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            Task { await self?.deleteProject(project, at: indexPath) }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func deleteProject(_ project: Project, at indexPath: IndexPath) async {
        showStatus("Deleting \"\(project.name)\"…")
        do {
            // 1. Fetch every point in this project (handles pagination).
            struct Item: Decodable { let id: String; let photos: [String]? }
            struct ListResult: Decodable { let items: [Item]; let nextToken: String? }
            struct ResponseData: Decodable { let listPoints: ListResult }
            let query = """
            query ListPoints($filter: ModelPointFilterInput, $nextToken: String) {
              listPoints(filter: $filter, nextToken: $nextToken) {
                items { id photos }
                nextToken
              }
            }
            """

            var all: [Item] = []
            var nextToken: String? = nil
            repeat {
                var vars: [String: Any] = ["filter": ["projectId": ["eq": project.id]]]
                if let t = nextToken { vars["nextToken"] = t }
                let req = GraphQLRequest<ResponseData>(
                    document: query, variables: vars, responseType: ResponseData.self)
                let result = try await Amplify.API.query(request: req)
                guard case .success(let data) = result else {
                    throw NSError(domain: "Delete", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Couldn't list points."])
                }
                all.append(contentsOf: data.listPoints.items)
                nextToken = data.listPoints.nextToken
            } while nextToken != nil

            // 2. Delete each point's S3 media, then the point itself.
            let pointDel = "mutation DeletePoint($input: DeletePointInput!) { deletePoint(input: $input) { id } }"
            struct PD: Decodable { let id: String }
            struct PR: Decodable { let deletePoint: PD }
            for item in all {
                for key in item.photos ?? [] {
                    _ = try? await Amplify.Storage.remove(path: .fromString(key))
                }
                let req = GraphQLRequest<PR>(document: pointDel,
                                             variables: ["input": ["id": item.id]],
                                             responseType: PR.self)
                _ = try await Amplify.API.mutate(request: req)
            }

            // 3. Delete the project itself.
            let projDel = "mutation DeleteProject($input: DeleteProjectInput!) { deleteProject(input: $input) { id } }"
            struct JD: Decodable { let id: String }
            struct JR: Decodable { let deleteProject: JD }
            let preq = GraphQLRequest<JR>(document: projDel,
                                          variables: ["input": ["id": project.id]],
                                          responseType: JR.self)
            _ = try await Amplify.API.mutate(request: preq)

            await MainActor.run {
                // If the deleted project was the active one, clear the selection.
                if ProjectStore.shared.current?.id == project.id {
                    ProjectStore.shared.clear()
                }
                self.projects.remove(at: indexPath.row)
                self.tableView.deleteRows(at: [indexPath], with: .automatic)
                if self.projects.isEmpty {
                    self.showStatus("No projects available yet.")
                } else {
                    self.statusLabel.isHidden = true
                }
            }
        } catch {
            await MainActor.run { showStatus("Delete failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Selection

    private func select(_ project: Project) {
        ProjectStore.shared.setCurrent(project)

        // Switching from the map: it already exists and reacts via `ProjectStore.onChange`.
        guard isGate else {
            dismiss(animated: true)
            return
        }

        // Gating: proceed into the map. Two ways we can have been shown:
        let mapVC = ViewController()
        mapVC.modalPresentationStyle = .fullScreen
        if let presenter = presentingViewController {
            // 1. Presented by the login/register screen → dismiss ourselves,
            //    then present the map from that same screen. (Don't go hunting
            //    through `UIWindowScene.windows` — after typing in the alert's
            //    text field, `windows.first` can be the keyboard window, whose
            //    rootViewController is nil, so the map never appeared.)
            presenter.dismiss(animated: true) {
                presenter.present(mapVC, animated: true)
            }
        } else if let window = view.window {
            // 2. We ARE the window's root (launched already signed in, see
            //    AppDelegate) → there is nothing to dismiss; swap the root.
            window.rootViewController = mapVC
            UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve, animations: nil)
        }
    }
}

// MARK: - Table

extension ProjectPickerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        projects.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectCell", for: indexPath)
        let p = projects[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = p.name
        content.secondaryText = String(format: "%.5f, %.5f", p.lat, p.lng)
        // Checkmark the currently-selected project, if any.
        cell.accessoryType = (ProjectStore.shared.current?.id == p.id) ? .checkmark : .none
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        select(projects[indexPath.row])
    }

    // Standard swipe-to-delete on each project row.
    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        confirmDelete(at: indexPath)
    }
}
