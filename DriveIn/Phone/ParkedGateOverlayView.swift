import UIKit

/// Covers web content or video while the car isn't parked.
final class ParkedGateOverlayView: UIView {
    enum Style {
        case phone
        /// Drawn in the CarPlay window: no buttons (CarPlay delivers no taps there).
        case car
    }

    var onConfirmParked: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let style: Style
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let confirmButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        setUp()
    }

    required init?(coder: NSCoder) {
        style = .phone
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        iconView.tintColor = .systemOrange
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: style == .car ? 34 : 48, weight: .semibold)

        titleLabel.font = .preferredFont(forTextStyle: style == .car ? .headline : .title2)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: style == .car ? .footnote : .body)
        detailLabel.textColor = UIColor(white: 1, alpha: 0.75)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        var confirm = UIButton.Configuration.filled()
        confirm.title = "I'm Parked"
        confirm.image = UIImage(systemName: "parkingsign.circle.fill")
        confirm.imagePadding = 8
        confirm.baseBackgroundColor = .systemOrange
        confirm.cornerStyle = .capsule
        confirm.buttonSize = .large
        confirmButton.configuration = confirm
        confirmButton.addAction(UIAction { [weak self] _ in self?.onConfirmParked?() }, for: .touchUpInside)

        var settings = UIButton.Configuration.tinted()
        settings.title = "Open Settings"
        settings.cornerStyle = .capsule
        settingsButton.configuration = settings
        settingsButton.addAction(UIAction { [weak self] _ in self?.onOpenSettings?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, detailLabel, confirmButton, settingsButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = style == .car ? 8 : 14
        stack.setCustomSpacing(style == .car ? 6 : 8, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: blur.contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.contentView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: blur.contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: blur.contentView.trailingAnchor, constant: -24),
        ])
    }

    /// - Parameter audioContinues: describe the audio-only behaviour instead of a pause.
    func configure(state: DrivingState, canConfirm: Bool, secondsRemaining: Int?, audioContinues: Bool, missingPermissions: [String]) {
        let soundNote = audioContinues ? " Sound keeps playing." : ""
        switch state {
        case .moving:
            iconView.image = UIImage(systemName: "car.side.fill")
            titleLabel.text = "Video is paused while driving"
            detailLabel.text = "DriveIn shows video only when the car is parked." + soundNote
        case .stopped:
            iconView.image = UIImage(systemName: "parkingsign.circle")
            if canConfirm {
                titleLabel.text = "Are you parked?"
                detailLabel.text = style == .car
                    ? "Choose “I'm Parked” on the CarPlay screen or on your iPhone."
                    : "Put the car in Park, then confirm to watch."
            } else if let seconds = secondsRemaining {
                titleLabel.text = "Stopped"
                detailLabel.text = "Video becomes available after the car stands still for \(seconds) more second\(seconds == 1 ? "" : "s")." + soundNote
            } else {
                titleLabel.text = "Stopped"
                detailLabel.text = "Waiting for the car to stand still." + soundNote
            }
        case .unknown:
            iconView.image = UIImage(systemName: "location.slash")
            titleLabel.text = "Can't tell if the car is parked"
            if missingPermissions.isEmpty {
                detailLabel.text = "Waiting for GPS or motion data. Video stays off until DriveIn knows the car is parked."
            } else {
                detailLabel.text = "Allow \(missingPermissions.joined(separator: " and ")) access so DriveIn can detect when the car is parked."
            }
        case .parked, .notConnected:
            iconView.image = UIImage(systemName: "checkmark.circle")
            titleLabel.text = "Parked"
            detailLabel.text = nil
        }
        confirmButton.isHidden = style == .car || !(state == .stopped && canConfirm)
        settingsButton.isHidden = style == .car || !(state == .unknown && !missingPermissions.isEmpty)
    }
}
