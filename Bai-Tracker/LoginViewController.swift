import UIKit
import Amplify

extension UIColor {
    static let appPurple = UIColor(red: 0.60, green: 0.40, blue: 0.85, alpha: 1.0)
}

final class LoginViewController: UIViewController {

    // MARK: - UI

    private let logoView: UIImageView = {
        let iv = UIImageView(image: UIImage(named: "bai"))
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        // 454 × 117 — wide banner
        iv.heightAnchor.constraint(equalTo: iv.widthAnchor, multiplier: 117.0 / 454.0).isActive = true
        return iv
    }()

    private let emailField: UITextField = {
        let f = UITextField()
        f.placeholder = "Email"
        f.keyboardType = .emailAddress
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.borderStyle = .roundedRect
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private let passwordField: UITextField = {
        let f = UITextField()
        f.placeholder = "Password"
        f.isSecureTextEntry = true
        f.borderStyle = .roundedRect
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private let signInButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Sign In"
        config.baseBackgroundColor = .appPurple
        let b = UIButton(configuration: config)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14)
        l.textColor = .systemRed
        l.textAlignment = .center
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// "Remember me on this device" — a checkbox-styled button plus its label,
    /// both toggling `rememberMe`.
    private let rememberMeButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "square")
        config.imagePadding = 8
        config.baseForegroundColor = .label
        config.contentInsets = .zero
        var title = AttributeContainer()
        title.font = .systemFont(ofSize: 14)
        config.attributedTitle = AttributedString("Remember me on this device",
                                                  attributes: title)
        let b = UIButton(configuration: config)
        b.contentHorizontalAlignment = .leading
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private var rememberMe = LoginPreferences.rememberMe

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // No self-registration: accounts are created by Bai Engineering and
        // scoped to a client, so there's nothing for a stranger to sign up for.
        let stack = UIStackView(arrangedSubviews: [
            logoView, emailField, passwordField, rememberMeButton,
            signInButton, statusLabel
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])

        signInButton.addTarget(self, action: #selector(handleSignIn), for: .touchUpInside)
        rememberMeButton.addTarget(self, action: #selector(toggleRememberMe), for: .touchUpInside)

        // Return key walks the fields, then submits.
        emailField.returnKeyType = .next
        passwordField.returnKeyType = .go
        emailField.delegate = self
        passwordField.delegate = self

        // Tapping the background dismisses the keyboard, which otherwise
        // covers `statusLabel` at the bottom of the stack.
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        view.addGestureRecognizer(dismissTap)

        // Restore the returning user's choice and prefill their email.
        updateRememberMeCheckbox()
        emailField.text = LoginPreferences.rememberedEmail
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    // MARK: - Remember me

    @objc private func toggleRememberMe() {
        rememberMe.toggle()
        updateRememberMeCheckbox()
    }

    private func updateRememberMeCheckbox() {
        rememberMeButton.configuration?.image =
            UIImage(systemName: rememberMe ? "checkmark.square.fill" : "square")
        rememberMeButton.configuration?.baseForegroundColor =
            rememberMe ? .appPurple : .label
        rememberMeButton.accessibilityLabel = "Remember me on this device"
        rememberMeButton.accessibilityValue = rememberMe ? "On" : "Off"
    }

    // MARK: - Actions

    @objc private func handleSignIn() {
        // Drop the keyboard first: it covers `statusLabel`, so without this a
        // failed sign-in looks like the button did nothing at all.
        view.endEditing(true)

        // Autofill and paste routinely tack a space onto the email, which
        // Cognito rejects as bad credentials.
        let email = (emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty,
              let password = passwordField.text, !password.isEmpty else {
            statusLabel.text = "Please enter email and password."
            return
        }
        setLoading(true)
        Task {
            do {
                let result = try await signInClearingStaleSession(username: email, password: password)
                if result.isSignedIn {
                    await finishSignIn(email: email)
                } else if case .confirmSignInWithNewPassword = result.nextStep {
                    // Accounts are created by an administrator with a temporary
                    // password; Cognito demands a real one on first sign-in.
                    await MainActor.run {
                        setLoading(false)
                        promptNewPassword(email: email)
                    }
                } else {
                    await MainActor.run {
                        statusLabel.text = "Additional steps required: \(result.nextStep)"
                        setLoading(false)
                    }
                }
            } catch {
                await MainActor.run {
                    statusLabel.text = error.localizedDescription
                    setLoading(false)
                }
            }
        }
    }

    /// Signs in, recovering from a leftover local session.
    ///
    /// A sign-out that fails to reach Cognito (expired tokens, no network)
    /// leaves the credentials in the keychain, so Cognito still considers the
    /// user signed in even though the app has returned to this screen. In that
    /// state `signIn` rejects every attempt with `.invalidState` and the user
    /// is stranded here permanently. Clear the stale session and retry once.
    private func signInClearingStaleSession(
        username: String,
        password: String
    ) async throws -> AuthSignInResult {
        do {
            return try await Amplify.Auth.signIn(username: username, password: password)
        } catch let error as AuthError {
            guard case .invalidState = error else { throw error }
            _ = await Amplify.Auth.signOut()
            return try await Amplify.Auth.signIn(username: username, password: password)
        }
    }

    /// Loads the user's groups before showing anything role-dependent, then
    /// enters the app.
    private func finishSignIn(email: String) async {
        await UserSession.shared.refresh()
        await MainActor.run {
            LoginPreferences.record(rememberMe: rememberMe, email: email)
            showMap()
        }
    }

    // MARK: - First sign-in password

    /// Asks an invited user to replace the temporary password Cognito emailed
    /// them.
    private func promptNewPassword(email: String) {
        let alert = UIAlertController(
            title: "Set a Password",
            message: "Choose a password for \(email). It needs 8+ characters"
                     + " with an uppercase letter, a lowercase letter, a number,"
                     + " and a symbol.",
            preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "New password"
            $0.isSecureTextEntry = true
            $0.textContentType = .newPassword
        }
        alert.addTextField {
            $0.placeholder = "Confirm password"
            $0.isSecureTextEntry = true
            $0.textContentType = .newPassword
        }
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let fields = alert?.textFields ?? []
            let password = fields.first?.text ?? ""
            let confirm = fields.count > 1 ? fields[1].text ?? "" : ""
            guard !password.isEmpty else { return }
            guard password == confirm else {
                statusLabel.text = "Passwords do not match."
                return
            }
            setLoading(true)
            Task {
                do {
                    let result = try await Amplify.Auth.confirmSignIn(challengeResponse: password)
                    if result.isSignedIn {
                        await self.finishSignIn(email: email)
                    } else {
                        await MainActor.run {
                            self.statusLabel.text = "Additional steps required: \(result.nextStep)"
                            self.setLoading(false)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.statusLabel.text = error.localizedDescription
                        self.setLoading(false)
                    }
                }
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showMap() {
        // Clear "Please wait…" now: this screen stays underneath the map /
        // project picker and is briefly visible again when they dismiss.
        setLoading(false)
        emailField.text = ""
        passwordField.text = ""
        if ProjectStore.shared.current != nil {
            let mapVC = ViewController()
            mapVC.modalPresentationStyle = .fullScreen
            present(mapVC, animated: true)
        } else {
            // First login with no project chosen → gate on the project picker.
            let picker = ProjectPickerViewController()
            picker.isGate = true
            let nav = UINavigationController(rootViewController: picker)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        }
    }

    private func setLoading(_ loading: Bool) {
        signInButton.isEnabled = !loading
        statusLabel.text = loading ? "Please wait…" : ""
        statusLabel.textColor = loading ? .secondaryLabel : .systemRed
    }
}

// MARK: - Text fields

extension LoginViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === emailField {
            passwordField.becomeFirstResponder()
        } else {
            handleSignIn()
        }
        return true
    }
}
