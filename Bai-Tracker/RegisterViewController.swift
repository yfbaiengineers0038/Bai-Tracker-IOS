import UIKit
import Amplify

final class RegisterViewController: UIViewController, UITextFieldDelegate {

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
        f.textContentType = .newPassword
        f.borderStyle = .roundedRect
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private let confirmPasswordField: UITextField = {
        let f = UITextField()
        f.placeholder = "Confirm Password"
        f.isSecureTextEntry = true
        f.textContentType = .newPassword
        f.borderStyle = .roundedRect
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    /// Live "passwords match / don't match" hint shown beneath the confirm field.
    private let matchHintLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12)
        l.textAlignment = .left
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let registerButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Create Account"
        config.baseBackgroundColor = .appPurple
        let b = UIButton(configuration: config)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let backButton: UIButton = {
        var config = UIButton.Configuration.bordered()
        config.title = "Back to Sign In"
        config.baseForegroundColor = .appPurple
        let b = UIButton(configuration: config)
        b.tintColor = .appPurple
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

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let stack = UIStackView(arrangedSubviews: [
            logoView, emailField, passwordField, confirmPasswordField,
            matchHintLabel, registerButton, backButton, statusLabel
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

        registerButton.addTarget(self, action: #selector(handleRegister), for: .touchUpInside)
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)

        // Live confirm-password match feedback
        passwordField.addTarget(self, action: #selector(updateMatchHint), for: .editingChanged)
        confirmPasswordField.addTarget(self, action: #selector(updateMatchHint), for: .editingChanged)
        matchHintLabel.text = ""

        // Dismiss keyboard on tap
        let tap = UITapGestureRecognizer(target: view, action: #selector(UIView.endEditing(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    // MARK: - Password match feedback

    @objc private func updateMatchHint() {
        let pw = passwordField.text ?? ""
        let confirm = confirmPasswordField.text ?? ""

        // Nothing to say until the user starts confirming.
        guard !confirm.isEmpty else {
            matchHintLabel.text = ""
            return
        }

        if confirm == pw {
            matchHintLabel.text = "Passwords match."
            matchHintLabel.textColor = .systemGreen
        } else {
            matchHintLabel.text = "Passwords do not match."
            matchHintLabel.textColor = .systemRed
        }
    }

    // MARK: - Actions

    @objc private func handleBack() {
        dismiss(animated: true)
    }

    @objc private func handleRegister() {
        statusLabel.textColor = .systemRed

        guard let email = emailField.text, !email.isEmpty,
              let password = passwordField.text, !password.isEmpty,
              let confirm = confirmPasswordField.text, !confirm.isEmpty else {
            statusLabel.text = "Please fill in all fields."
            return
        }

        // Verify the password the user entered twice actually matches.
        guard password == confirm else {
            statusLabel.text = "Passwords do not match."
            return
        }

        // Client-side check of the Cognito password policy so users get a
        // friendly message instead of a raw backend error. Policy comes from
        // amplify_outputs.json: min 8, upper, lower, digit, symbol.
        if let policyError = passwordPolicyError(password) {
            statusLabel.text = policyError
            return
        }

        setLoading(true)
        Task {
            do {
                let userAttributes = [AuthUserAttribute(.email, value: email)]
                let options = AuthSignUpRequest.Options(userAttributes: userAttributes)
                let result = try await Amplify.Auth.signUp(username: email, password: password, options: options)
                await MainActor.run {
                    setLoading(false)
                    switch result.nextStep {
                    case .confirmUser:
                        promptConfirmation(email: email, password: password)
                    case .done:
                        Task { await self.signInAfterSignUp(email: email, password: password) }
                    default:
                        self.statusLabel.text = "Unexpected sign-up step: \(result.nextStep)"
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

    // MARK: - Email confirmation code

    private func promptConfirmation(email: String, password: String) {
        let alert = UIAlertController(title: "Verify Account",
                                      message: "Enter the code sent to \(email)",
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Confirmation code"
            $0.keyboardType = .numberPad }
        alert.addAction(UIAlertAction(title: "Confirm", style: .default) { [weak self, weak alert] _ in
            guard let code = alert?.textFields?.first?.text, !code.isEmpty else { return }
            self?.setLoading(true)
            Task {
                do {
                    try await Amplify.Auth.confirmSignUp(for: email, confirmationCode: code)
                    await self?.signInAfterSignUp(email: email, password: password)
                } catch {
                    await MainActor.run {
                        self?.statusLabel.text = error.localizedDescription
                        self?.setLoading(false)
                    }
                }
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Helpers

    private func signInAfterSignUp(email: String, password: String) async {
        do {
            let result = try await Amplify.Auth.signIn(username: email, password: password)
            if result.isSignedIn {
                await MainActor.run { showMap() }
            }
        } catch {
            await MainActor.run {
                statusLabel.text = error.localizedDescription
                setLoading(false)
            }
        }
    }

    private func showMap() {
        setLoading(false) // this screen is briefly visible again when the picker dismisses
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
        registerButton.isEnabled = !loading
        backButton.isEnabled = !loading
        statusLabel.text = loading ? "Please wait…" : ""
        statusLabel.textColor = loading ? .secondaryLabel : .systemRed
    }

    /// Returns a human-readable message describing which part of the Cognito
    /// password policy a password fails, or `nil` if the password is valid.
    /// Policy (from amplify_outputs.json): ≥ 8 chars, upper + lower + digit + symbol.
    private func passwordPolicyError(_ password: String) -> String? {
        if password.count < 8 {
            return "Password must be at least 8 characters."
        }
        let hasUpper = password.range(of: "[A-Z]", options: .regularExpression) != nil
        let hasLower = password.range(of: "[a-z]", options: .regularExpression) != nil
        let hasDigit = password.range(of: "[0-9]", options: .regularExpression) != nil
        let hasSymbol = password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil

        var missing: [String] = []
        if !hasUpper { missing.append("an uppercase letter") }
        if !hasLower { missing.append("a lowercase letter") }
        if !hasDigit { missing.append("a number") }
        if !hasSymbol { missing.append("a symbol") }

        guard missing.isEmpty else {
            return "Password must contain \(missing.joined(separator: ", "))."
        }
        return nil
    }
}
