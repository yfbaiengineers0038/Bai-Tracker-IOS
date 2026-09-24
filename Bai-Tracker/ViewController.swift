import UIKit
import GoogleMaps
import CoreLocation
import Amplify
import AWSCognitoAuthPlugin

final class ViewController: UIViewController {

    private let defaultCamera = GMSCameraPosition(
        latitude: 35.7796,
        longitude: -78.6382,
        zoom: 12.0
    )

    /// Camera built from the selected project's lat/lng/zoom, falling back to
    /// the hardcoded default when no project is chosen.
    private var activeCamera: GMSCameraPosition {
        if let p = ProjectStore.shared.current {
            return GMSCameraPosition(latitude: p.lat, longitude: p.lng, zoom: Float(p.zoom))
        }
        return defaultCamera
    }

    private var mapView: GMSMapView!
    private var mapTypeControl: UISegmentedControl!
    private let locationManager = CLLocationManager()
    private var markerMap: [GMSMarker: PointData] = [:]
    /// Visible geographic circles (radius in meters) drawn under the markers,
    /// so markers scale correctly with zoom instead of drifting.
    private var circleMap: [String: GMSCircle] = [:]
    private var isPlacingPoint = false
    private var placementBanner: UIView!
    private var placementLabel: UILabel!
    /// Floating "Confirm" pill that pops up below the banner while placing
    /// a point — the prominent call-to-action (replaces an in-banner button).
    private var confirmButton: UIButton!
    /// Floating "Cancel" pill shown to the left of Confirm while placing.
    private var cancelButton: UIButton!
    /// The bottom stack holding the Cancel + Confirm pills.
    private var actionPillStack: UIStackView!
    /// Fixed reticle pinned to screen center while placing a point (Lyft-style:
    /// the map moves under it; the coordinate at center is the selection).
    private var centerPinView: UIImageView!

    /// All loaded points, kept sorted most-recent-first for the bottom sheet.
    private var points: [PointData] = []
    private var pointsSheet: PointListBottomSheet!
    private var mapControlStack: UIStackView!

    /// Geographic radius (meters) for point circles. Geographic, not pixel,
    /// so it stays anchored to the coordinate at any zoom.
    private let pointCircleRadius: CLLocationDistance = 1

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupMapView()
        setupMapTypeControl()
        setupMapControls()
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        setupPlacementBanner()
        setupLogoutButton()
        setupCenterPin()
        setupPointsSheet()
        setupConfirmButton()
        // When the user switches projects (via the folder button), reload
        // points filtered to the new project and re-center the camera.
        ProjectStore.shared.onChange = { [weak self] in
            DispatchQueue.main.async { self?.reloadPoints() }
        }
        Task { await loadPoints() }
    }

    // MARK: - Map

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        relayoutPointLabels()
    }

    private func setupMapView() {
        mapView = GMSMapView(frame: .zero, camera: activeCamera)
        mapView.mapType = .satellite
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.isMyLocationEnabled = true
        mapView.settings.myLocationButton = false
        mapView.settings.compassButton = true
        mapView.settings.zoomGestures = true
        mapView.settings.scrollGestures = true
        mapView.settings.rotateGestures = true
        mapView.settings.tiltGestures = true

        view.addSubview(mapView)

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// Fixed reticle pinned to the exact screen center, shown only while
    /// placing a point. It's a sibling of the map (not an overlay), so it
    /// never moves when the map is dragged — the coordinate at center is
    /// the selection.
    private func setupCenterPin() {
        let pin = UIImageView(image: Self.makeMapPinImage())
        // Subtle shadow so it reads over satellite/any map.
        pin.layer.shadowColor = UIColor.black.cgColor
        pin.layer.shadowOpacity = 0.35
        pin.layer.shadowRadius = 3
        pin.layer.shadowOffset = CGSize(width: 0, height: 2)
        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.isHidden = true
        view.addSubview(pin)
        NSLayoutConstraint.activate([
            pin.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // Align the pin's bottom tip to true screen center.
            pin.bottomAnchor.constraint(equalTo: view.centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 36),
            pin.heightAnchor.constraint(equalToConstant: 48)
        ])
        centerPinView = pin
    }

    /// Draws the classic Apple-Maps-style pin: a filled red teardrop with a
    /// white center dot, pointing down. The tip is the selected coordinate.
    private static func makeMapPinImage() -> UIImage {
        let size = CGSize(width: 36, height: 48)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let c = ctx.cgContext
            let fill = UIColor.systemRed

            // Teardrop body: a rounded-rect head narrowing to a point at the
            // bottom. Built as a path: top semicircle + two straight sides
            // converging to the tip.
            let headDiameter: CGFloat = 30
            let headRect = CGRect(x: (size.width - headDiameter) / 2,
                                  y: 0, width: headDiameter, height: headDiameter)
            let tip = CGPoint(x: size.width / 2, y: size.height)

            let path = UIBezierPath()
            // Top semicircle (left to right across the top).
            path.addArc(withCenter: CGPoint(x: headRect.midX, y: headRect.midY),
                        radius: headDiameter / 2,
                        startAngle: .pi, endAngle: 0, clockwise: true)
            // Right side down to the tip.
            path.addLine(to: tip)
            // Left side back up to the start of the arc.
            path.addLine(to: CGPoint(x: headRect.minX, y: headRect.midY))
            path.close()

            fill.setFill()
            path.fill()

            // White center dot.
            let dotDiameter: CGFloat = 10
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(
                x: headRect.midX - dotDiameter / 2,
                y: headRect.midY - dotDiameter / 2,
                width: dotDiameter, height: dotDiameter)).fill()
        }
    }

    // MARK: - Map Controls

    private func setupMapControls() {
        // "New Point" button — moved to the top-right and labelled so its
        // purpose is obvious (was a bare "N" at the bottom-right).
        let newBtn = UIButton(type: .system)
        newBtn.setTitle("New Point", for: .normal)
        newBtn.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        newBtn.setTitleColor(.white, for: .normal)
        newBtn.backgroundColor = .appPurple
        newBtn.layer.cornerRadius = 26
        newBtn.layer.shadowColor = UIColor.black.cgColor
        newBtn.layer.shadowOffset = CGSize(width: 0, height: 2)
        newBtn.layer.shadowOpacity = 0.18
        newBtn.layer.shadowRadius = 4
        newBtn.translatesAutoresizingMaskIntoConstraints = false
        newBtn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        newBtn.heightAnchor.constraint(equalToConstant: 52).isActive = true
        newBtn.addTarget(self, action: #selector(startPlacingPoint), for: .touchUpInside)
        view.addSubview(newBtn)
        NSLayoutConstraint.activate([
            newBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            newBtn.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12)
        ])

        let zoomIn  = makeIconMapButton(systemImage: "plus",          action: #selector(zoomIn))
        let zoomOut = makeIconMapButton(systemImage: "minus",         action: #selector(zoomOut))
        let locate  = makeIconMapButton(systemImage: "location.fill", action: #selector(locateMe))
        locate.tintColor = .appPurple

        let stack = UIStackView(arrangedSubviews: [zoomIn, zoomOut, locate])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        mapControlStack = stack

        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12)
            // Bottom anchor is set in setupPointsSheet() so the stack rides
            // just above the bottom sheet instead of the screen edge.
        ])
    }

    /// Height of the round icon buttons in the top-left row, so the map-type
    /// control below them can clear the row.
    private static let topControlsRowHeight: CGFloat = 44

    private func setupLogoutButton() {
        // Switch-project button, top-left. (Sign Out used to be a one-tap red
        // button in this slot, which made it easy to hit by accident; it now
        // lives in the overflow menu at the end of this row.)
        let switchBtn = makeIconMapButton(systemImage: "folder", action: #selector(switchProject))
        switchBtn.tintColor = .appPurple
        switchBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(switchBtn)
        NSLayoutConstraint.activate([
            switchBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            switchBtn.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12)
        ])

        // Labels toggle sits just right of switch-project, top-left.
        let toggleBtn = makeIconMapButton(systemImage: "tag", action: #selector(toggleLabels))
        toggleBtn.tintColor = .appPurple
        toggleBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toggleBtn)
        NSLayoutConstraint.activate([
            toggleBtn.topAnchor.constraint(equalTo: switchBtn.topAnchor),
            toggleBtn.leadingAnchor.constraint(equalTo: switchBtn.trailingAnchor, constant: 8)
        ])
        labelsToggleButton = toggleBtn
        updateLabelsToggleAppearance()

        // Overflow menu, last in the row. A stray tap just opens a menu, and
        // signing out from it still has to clear a confirmation.
        let moreBtn = makeIconMapButton(systemImage: "ellipsis", action: #selector(noop))
        moreBtn.tintColor = .appPurple
        moreBtn.translatesAutoresizingMaskIntoConstraints = false
        moreBtn.showsMenuAsPrimaryAction = true
        moreBtn.menu = UIMenu(children: [
            UIAction(title: "Sign Out",
                     image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                     attributes: .destructive) { [weak self] _ in
                self?.confirmSignOut()
            }
        ])
        view.addSubview(moreBtn)
        NSLayoutConstraint.activate([
            moreBtn.topAnchor.constraint(equalTo: switchBtn.topAnchor),
            moreBtn.leadingAnchor.constraint(equalTo: toggleBtn.trailingAnchor, constant: 8)
        ])
    }

    /// `makeIconMapButton` requires a selector; the menu handles the tap.
    @objc private func noop() {}

    private func confirmSignOut() {
        let alert = UIAlertController(
            title: "Sign Out?",
            message: "You'll need to enter your email and password to get back in.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
            self?.logout()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func toggleLabels() {
        labelsEnabled.toggle()
        updateLabelsToggleAppearance()
        relayoutPointLabels()
    }

    /// Dim the toggle button when labels are off, so it reads as a state.
    private func updateLabelsToggleAppearance() {
        labelsToggleButton.alpha = labelsEnabled ? 1.0 : 0.4
    }

    private func setupPointsSheet() {
        let sheet = PointListBottomSheet()
        sheet.translatesAutoresizingMaskIntoConstraints = false
        sheet.delegate = self
        view.addSubview(sheet)
        pointsSheet = sheet

        NSLayoutConstraint.activate([
            sheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Ride the zoom controls just above the sheet so they stay usable
            // when it expands.
            mapControlStack.bottomAnchor.constraint(equalTo: sheet.topAnchor, constant: -12)
        ])

        // Sheet sits above the map + controls.
        view.bringSubviewToFront(sheet)
    }

    private func setupPlacementBanner() {
        let banner = UIView()
        banner.backgroundColor = UIColor.appPurple.withAlphaComponent(0.92)
        banner.layer.cornerRadius = 10
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true

        let label = UILabel()
        label.text = "Drag the map to position the pin"
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(label)

        let cancelBtn = UIButton(type: .system)
        cancelBtn.setTitle("Cancel", for: .normal)
        cancelBtn.setTitleColor(.white, for: .normal)
        cancelBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        cancelBtn.addTarget(self, action: #selector(cancelPlacing), for: .touchUpInside)
        banner.addSubview(cancelBtn)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cancelBtn.leadingAnchor, constant: -12),

            cancelBtn.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -16),
            cancelBtn.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

            banner.heightAnchor.constraint(equalToConstant: 44)
        ])

        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: mapTypeControl.bottomAnchor, constant: 12),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
        placementBanner = banner
        placementLabel = label
    }

    /// Floating action pills that pop up at the bottom when placement is
    /// active: "Cancel" (left) and "Confirm" (right) — the clear call-to-action
    /// to lock in the point, with cancel always within reach.
    private func setupConfirmButton() {
        var confirmConfig = UIButton.Configuration.filled()
        confirmConfig.title = "Confirm"
        confirmConfig.baseBackgroundColor = .appPurple
        confirmConfig.cornerStyle = .large
        confirmConfig.buttonSize = .large
        let confirmBtn = UIButton(configuration: confirmConfig)
        confirmBtn.translatesAutoresizingMaskIntoConstraints = false
        confirmBtn.addTarget(self, action: #selector(confirmPlacement), for: .touchUpInside)
        confirmButton = confirmBtn

        var cancelConfig = UIButton.Configuration.filled()
        cancelConfig.title = "Cancel"
        cancelConfig.baseBackgroundColor = .systemRed
        cancelConfig.cornerStyle = .large
        cancelConfig.buttonSize = .large
        let cancelBtn = UIButton(configuration: cancelConfig)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        cancelBtn.addTarget(self, action: #selector(cancelPlacing), for: .touchUpInside)
        cancelButton = cancelBtn

        let stack = UIStackView(arrangedSubviews: [cancelBtn, confirmBtn])
        stack.axis = .horizontal
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Only the stack's visibility is toggled — the buttons inside stay visible.
        stack.isHidden = true
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            // Float above the bottom points sheet so it's easy to reach.
            stack.bottomAnchor.constraint(equalTo: pointsSheet.topAnchor, constant: -24)
        ])
        actionPillStack = stack
    }

    /// Screen-anchored per-point name labels. One small `UILabel` per point,
    /// repositioned on each camera change via the map projection so it tracks
    /// its point at a constant screen size (no scaling on zoom). Hidden unless
    /// zoomed in to avoid clutter.
    private var pointLabels: [String: UILabel] = [:]

    /// Minimum zoom at which per-point name labels appear (street level).
    private let labelMinZoom: Float = 17

    /// User toggle for the per-point name labels. When off, labels never show.
    private var labelsEnabled = true
    private var labelsToggleButton: UIButton!

    private func makeIconMapButton(systemImage: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        let img = UIImage(systemName: systemImage,
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        button.setImage(img, for: .normal)
        button.tintColor = .label
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 22
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 4
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeTextMapButton(text: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(text, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 22
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 4
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    /// Shows a brief, auto-dismissing toast near the top of the screen.
    private func showToast(_ message: String) {
        let toast = UILabel()
        toast.text = message
        toast.font = .systemFont(ofSize: 15, weight: .medium)
        toast.textColor = .white
        toast.textAlignment = .center
        toast.numberOfLines = 0
        toast.backgroundColor = UIColor.appPurple.withAlphaComponent(0.95)
        toast.layer.cornerRadius = 14
        toast.layer.shadowColor = UIColor.black.cgColor
        toast.layer.shadowOffset = CGSize(width: 0, height: 2)
        toast.layer.shadowOpacity = 0.2
        toast.layer.shadowRadius = 4
        toast.clipsToBounds = true

        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.backgroundColor = .clear
        toast.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(toast)

        view.addSubview(wrap)
        NSLayoutConstraint.activate([
            wrap.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
            wrap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            wrap.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            wrap.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            toast.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10),
            toast.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10),
            toast.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 18),
            toast.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -18)
        ])

        // Slide/fade in, hold, then fade out and remove.
        wrap.alpha = 0
        wrap.transform = CGAffineTransform(translationX: 0, y: -8)
        UIView.animate(withDuration: 0.25) {
            wrap.alpha = 1
            wrap.transform = .identity
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.35, animations: {
                wrap.alpha = 0
                wrap.transform = CGAffineTransform(translationX: 0, y: -8)
            }, completion: { _ in wrap.removeFromSuperview() })
        }
    }

    @objc private func zoomIn()  { mapView.animate(with: GMSCameraUpdate.zoomIn()) }
    @objc private func zoomOut() { mapView.animate(with: GMSCameraUpdate.zoomOut()) }

    @objc private func locateMe() {
        guard let location = mapView.myLocation else { locationManager.requestLocation(); return }
        mapView.animate(with: GMSCameraUpdate.setTarget(location.coordinate, zoom: 15))
    }

    @objc private func startPlacingPoint() {
        isPlacingPoint = true
        // Map must remain draggable so the user can move it under the fixed
        // center pin (Lyft-style placement).
        mapView.settings.scrollGestures = true
        placementBanner.isHidden = false
        view.bringSubviewToFront(placementBanner)
        pointLabels.values.forEach { $0.isHidden = true } // clean view while placing

        // Show the fixed center pin with a scale-pop.
        centerPinView.isHidden = false
        view.bringSubviewToFront(centerPinView)
        centerPinView.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        UIView.animate(withDuration: 0.25, delay: 0,
                       usingSpringWithDamping: 0.5, initialSpringVelocity: 0.6,
                       options: [], animations: {
            self.centerPinView.transform = .identity
        })

        // Pop up the floating Cancel + Confirm pills.
        actionPillStack.isHidden = false
        view.bringSubviewToFront(actionPillStack)
        actionPillStack.alpha = 0
        actionPillStack.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        UIView.animate(withDuration: 0.3, delay: 0.05,
                       usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5,
                       options: [], animations: {
            self.actionPillStack.alpha = 1
            self.actionPillStack.transform = .identity
        })

        // Seed the readout with whatever is currently at screen center.
        updatePlacementLabel(for: mapView.camera.target)
    }

    @objc private func cancelPlacing() { resetPlacement() }

    @objc private func confirmPlacement() {
        // Lyft model: the selected location is whatever sits at screen center
        // (under the fixed pin), i.e. the map's current camera target.
        let coord = mapView.camera.target
        resetPlacement()
        let vc = NewPointViewController(coordinate: coord)
        vc.delegate = self
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    /// Clears the placement pin, banner, and state.
    private func resetPlacement() {
        isPlacingPoint = false
        mapView.settings.scrollGestures = true
        centerPinView.isHidden = true
        actionPillStack.isHidden = true
        placementBanner.isHidden = true
    }

    /// Updates the banner to reflect the coordinate under the center pin.
    private func updatePlacementLabel(for coordinate: CLLocationCoordinate2D) {
        placementLabel.text = String(format: "Drag the map to position the pin  (%.5f, %.5f)",
                                     coordinate.latitude, coordinate.longitude)
    }

    @objc private func logout() {
        Task {
            let result = await Amplify.Auth.signOut()

            // A sign-out that never reached Cognito leaves the credentials in
            // the keychain. Returning to the login screen anyway strands the
            // user: Cognito still sees them as signed in, so every subsequent
            // sign-in is rejected with `.invalidState`. Stay put and say so.
            if let cognitoResult = result as? AWSCognitoSignOutResult,
               !cognitoResult.signedOutLocally {
                await MainActor.run { showSignOutFailedAlert() }
                return
            }

            await MainActor.run {
                ProjectStore.shared.clear() // forget selected project on logout
                let login = LoginViewController()
                login.modalPresentationStyle = .fullScreen
                login.modalTransitionStyle = .crossDissolve
                present(login, animated: true)
            }
        }
    }

    private func showSignOutFailedAlert() {
        let alert = UIAlertController(
            title: "Couldn't Sign Out",
            message: "Check your connection and try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func switchProject() {
        let picker = ProjectPickerViewController()
        picker.isGate = false
        // Center any newly-created project on where the user is looking.
        picker.initialCamera = (mapView.camera.target.latitude,
                                mapView.camera.target.longitude,
                                Double(mapView.camera.zoom))
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    // MARK: - Amplify

    /// Clears all loaded points/markers/circles and reloads from the backend,
    /// filtered by the currently-selected project. Used on first load and on
    /// project switch.
    private func reloadPoints() {
        // Clear existing markers/circles/labels/list.
        for m in markerMap.keys { m.map = nil }
        markerMap.removeAll()
        for c in circleMap.values { c.map = nil }
        circleMap.removeAll()
        for l in pointLabels.values { l.removeFromSuperview() }
        pointLabels.removeAll()
        points.removeAll()
        pointsSheet?.update(points)

        // Re-center on the (possibly new) project's camera.
        mapView.animate(to: activeCamera)

        Task { await loadPoints() }
    }

    /// Repositions every per-point name label above its point using the current
    /// map projection, at a constant screen size. Labels are shown only when
    /// enabled AND zoomed in (>= labelMinZoom) to avoid clutter.
    private func relayoutPointLabels() {
        guard !isPlacingPoint else { return }
        // If the user toggled labels off, hide them all.
        guard labelsEnabled else {
            pointLabels.values.forEach { $0.isHidden = true }
            return
        }
        let showLabels = mapView.camera.zoom >= labelMinZoom
        for point in points {
            guard let label = pointLabels[point.id] else { continue }
            guard showLabels else { label.isHidden = true; continue }

            let coord = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng)
            let screen = mapView.projection.point(for: coord)
            // Skip if the point is off-screen.
            guard mapView.bounds.contains(screen) else { label.isHidden = true; continue }

            // Size to current text, then sit centered above the point.
            label.sizeToFit()
            var f = label.frame
            f.size.width += 16
            f.size.height += 6
            f.origin.x = screen.x - f.width / 2
            f.origin.y = screen.y - f.height - 8
            label.frame = f
            label.isHidden = false
        }
    }

    private func loadPoints() async {
        let projectId = ProjectStore.shared.current?.id

        // Filter by projectId when a project is selected (Lawrence's schema
        // requires it); otherwise fall back to unfiltered for safety.
        let query = """
        query ListPoints($filter: ModelPointFilterInput) {
          listPoints(filter: $filter) {
            items {
              id date time location description lat lng photos timezone comments category projectId
            }
          }
        }
        """

        struct Item: Decodable {
            let id: String
            let date: String
            let time: String?
            let location: String?
            let description: String?
            let lat: Double
            let lng: Double
            let photos: [String]?
            let timezone: String?
            let comments: [String]?
            let category: String?
            let projectId: String?
        }
        struct ListResult: Decodable { let items: [Item] }
        struct ResponseData: Decodable { let listPoints: ListResult }

        let filter: [String: Any]? = projectId.map {
            ["projectId": ["eq": $0]]
        }
        let request = GraphQLRequest<ResponseData>(
            document: query, variables: filter.map { ["filter": $0] },
            responseType: ResponseData.self)

        do {
            let result = try await Amplify.API.query(request: request)
            guard case .success(let data) = result else { return }
            let items = data.listPoints.items
            guard !items.isEmpty else { return }

            var bounds = GMSCoordinateBounds()
            await MainActor.run {
                for item in items {
                    let coord = CLLocationCoordinate2D(latitude: item.lat, longitude: item.lng)
                    bounds = bounds.includingCoordinate(coord)
                    let point = PointData(id: item.id, date: item.date, time: item.time,
                                         location: item.location, description: item.description,
                                         lat: item.lat, lng: item.lng,
                                         photos: item.photos ?? [],
                                         timezone: item.timezone,
                                         comments: item.comments ?? [],
                                         category: item.category,
                                         projectId: item.projectId)
                    addMarker(for: point)
                    self.points.append(point)
                }
                self.sortPoints()
                self.pointsSheet?.update(self.points)
                mapView.animate(with: GMSCameraUpdate.fit(bounds, withPadding: 60))
                self.relayoutPointLabels()
            }
        } catch {
            print("API query failed: \(error)")
        }
    }

    /// Sort points most-recent-first. `date` is `yyyy-MM-dd` and `time` is
    /// `HH:mm`, so a lexical sort on the combined key == chronological.
    private func sortPoints() {
        points.sort { key($0) > key($1) }
    }

    private func key(_ p: PointData) -> String {
        p.date + " " + (p.time ?? "00:00")
    }

    func addMarker(for point: PointData) {
        let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng)
        let color = CategoryColors.color(for: point.category)

        // Visible geographic circle — radius in meters, so it scales with zoom
        // and stays anchored to the coordinate (no drift).
        let circle = GMSCircle(position: coordinate, radius: pointCircleRadius)
        // Solid dot: opaque fill, no rim.
        circle.fillColor = color
        circle.strokeWidth = 0
        circle.map = mapView
        circleMap[point.id] = circle

        // Invisible tap target at the same coordinate (GMSCircle is not
        // tappable on iOS), keeping the existing didTap marker flow working.
        let marker = GMSMarker(position: coordinate)
        marker.icon = makeInvisibleIcon()
        marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
        marker.map = mapView
        markerMap[marker] = point

        // Per-point name label (screen-space, repositioned on camera change).
        pointLabels[point.id] = makePointLabel(for: point)
        if let label = pointLabels[point.id] {
            view.addSubview(label)
        }
    }

    /// Builds a small floating label showing the point's location name.
    private func makePointLabel(for point: PointData) -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.sizeToFit()
        // Pad the text inside the pill.
        label.frame.size.width += 16
        label.frame.size.height += 6
        let name = point.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        label.text = (name?.isEmpty ?? true) ? "Untitled" : name
        label.isHidden = true
        return label
    }

    func removeMarker(for pointID: String) {
        if let entry = markerMap.first(where: { $0.value.id == pointID }) {
            entry.key.map = nil
            markerMap.removeValue(forKey: entry.key)
        }
        if let circle = circleMap.removeValue(forKey: pointID) {
            circle.map = nil
        }
        if let label = pointLabels.removeValue(forKey: pointID) {
            label.removeFromSuperview()
        }
    }

    func updateMarker(for point: PointData) {
        if let entry = markerMap.first(where: { $0.value.id == point.id }) {
            markerMap[entry.key] = point
        }
        // Refresh the circle color in case the category (and thus color) changed.
        if let circle = circleMap[point.id] {
            circle.fillColor = CategoryColors.color(for: point.category)
        }
        // Refresh the name label if the location changed.
        if let label = pointLabels[point.id] {
            let name = point.location?.trimmingCharacters(in: .whitespacesAndNewlines)
            label.text = (name?.isEmpty ?? true) ? "Untitled" : name
            label.sizeToFit()
            label.frame.size.width += 16
            label.frame.size.height += 6
        }
    }

    /// A transparent 44×44 icon so the marker stays visually invisible while
    /// providing a comfortable tap target (iOS's 44pt minimum) to open detail.
    private func makeInvisibleIcon() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 44, height: 44))
        return renderer.image { _ in UIColor.clear.setFill() }
    }

    // MARK: - Map Type Control

    private func setupMapTypeControl() {
        mapTypeControl = UISegmentedControl(items: ["Map", "Satellite"])
        mapTypeControl.translatesAutoresizingMaskIntoConstraints = false
        mapTypeControl.selectedSegmentIndex = 1 // default to Satellite
        mapTypeControl.backgroundColor = .systemBackground
        mapTypeControl.selectedSegmentTintColor = .appPurple
        mapTypeControl.layer.shadowColor = UIColor.black.cgColor
        mapTypeControl.layer.shadowOffset = CGSize(width: 0, height: 2)
        mapTypeControl.layer.shadowOpacity = 0.2
        mapTypeControl.layer.shadowRadius = 4
        mapTypeControl.addTarget(self, action: #selector(mapTypeChanged), for: .valueChanged)

        view.addSubview(mapTypeControl)

        // Own row, below the top-left icon buttons. Centered on the first row
        // it collided with them: the icons (3 × 44 + gaps = 148pt) reach past
        // the centered control's leading edge on a phone-width screen, and
        // icons + control + "New Point" don't fit on one row at all.
        NSLayoutConstraint.activate([
            mapTypeControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                                constant: Self.topControlsRowHeight + 20),
            mapTypeControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                                                    constant: 12)
        ])
    }

    @objc private func mapTypeChanged() {
        mapView.mapType = mapTypeControl.selectedSegmentIndex == 0 ? .normal : .satellite
    }

    /// Presents the point-detail page sheet for the given point.
    private func openDetail(for point: PointData) {
        let detail = PointDetailViewController(point: point)
        detail.delegate = self
        let nav = UINavigationController(rootViewController: detail)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }
}

// MARK: - GMSMapViewDelegate

extension ViewController: GMSMapViewDelegate {
    func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
        guard !isPlacingPoint else { return false }
        guard let point = markerMap[marker] else { return false }
        openDetail(for: point)
        return true
    }

    func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) {
        // Lyft-style placement: the map is dragged under a fixed center pin,
        // so tapping the map does nothing during placement.
        guard !isPlacingPoint else { return }
    }

    // MARK: - Camera tracking (live center-coordinate readout while placing)

    func mapView(_ mapView: GMSMapView, didChange position: GMSCameraPosition) {
        if isPlacingPoint {
            updatePlacementLabel(for: position.target)
        } else {
            relayoutPointLabels()
        }
    }
}

// MARK: - PointDetailDelegate

extension ViewController: PointDetailDelegate {
    func pointDetailDidUpdate(_ point: PointData) {
        updateMarker(for: point)
        // Replace the stale point in the list, re-sort, refresh the sheet.
        if let i = points.firstIndex(where: { $0.id == point.id }) {
            points[i] = point
            sortPoints()
            pointsSheet?.update(points)
        }
        relayoutPointLabels()
    }
    func pointDetailDidDelete(id: String) {
        removeMarker(for: id)
        points.removeAll { $0.id == id }
        pointsSheet?.update(points)
        relayoutPointLabels()
    }
    func pointDetailDidCreate(_ point: PointData)  {
        addMarker(for: point)
        points.insert(point, at: 0) // newest-first
        pointsSheet?.update(points)
        showToast("Your point has been successfully uploaded")
        relayoutPointLabels()
    }
}

// MARK: - PointListSheetDelegate

extension ViewController: PointListSheetDelegate {
    func sheet(_ sheet: PointListBottomSheet, didTapLocate point: PointData) {
        let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng)
        // Zoom in tight on the exact point (3m circles need a high zoom to be visible).
        mapView.animate(with: GMSCameraUpdate.setTarget(coordinate, zoom: 20))
        sheet.collapse() // get out of the way so the point is visible
    }

    func sheet(_ sheet: PointListBottomSheet, didTapEdit point: PointData) {
        openDetail(for: point)
    }

    func sheet(_ sheet: PointListBottomSheet, didSelectRow point: PointData) {
        openDetail(for: point)
    }
}

// MARK: - CLLocationManagerDelegate

extension ViewController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }
}
