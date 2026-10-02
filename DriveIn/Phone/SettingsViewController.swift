import CoreLocation
import CoreMotion
import UIKit

final class SettingsViewController: UITableViewController {
    private enum Row {
        case requireConfirmation
        case parkedDelay
        case audioContinues
        case simulation
        case searchEngine
        case desktopSites
        case carCompatibleVideo
        case locationPermission
        case motionPermission
        case frameMirror
        case capabilities
        case restoreBookmarks
        case version
    }

    private struct Section {
        let title: String
        let footer: String?
        let rows: [Row]
    }

    private let sections: [Section] = [
        Section(title: "Parked-only video",
                footer: "While your iPhone is connected to CarPlay (wired or wireless), video plays only when DriveIn believes the car is parked: it must stand still for the set time and, if required, you confirm with “I'm Parked”. Cars that support AirPlay or CarPlay video also enforce this themselves. Simulate CarPlay is for testing at home and is ignored while a real car is connected.",
                rows: [.requireConfirmation, .parkedDelay, .audioContinues, .simulation]),
        Section(title: "Browser",
                footer: "Car-compatible video hides Media Source Extensions from websites so they fall back to plain HLS/MP4 streams, as they do for older iPhones. Those streams can be played by DriveIn's player, AirPlayed to the car and shown in CarPlay. Quality may be lower; DRM sites (Netflix, Disney+) still only play inside the page.",
                rows: [.searchEngine, .desktopSites, .carCompatibleVideo]),
        Section(title: "Permissions", footer: nil, rows: [.locationPermission, .motionPermission]),
        Section(title: "Experimental",
                footer: "Copies about one video frame per second into the Now Playing artwork. Any app may do this without a CarPlay entitlement, and CarPlay's Now Playing screen shows the artwork. It's a slideshow, not real video, and only runs while parked.",
                rows: [.frameMirror]),
        Section(title: "About", footer: nil, rows: [.capabilities, .restoreBookmarks, .version]),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reloadSettings), name: .settingsDidChange, object: nil)
        center.addObserver(self, selector: #selector(reloadSettings), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func reloadSettings() {
        // Deferred: the change usually comes from a control inside this table.
        DispatchQueue.main.async { [weak self] in
            self?.tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.valueCell()
        let settings = AppSettings.shared
        let monitor = DrivingStateMonitor.shared

        switch sections[indexPath.section].rows[indexPath.row] {
        case .requireConfirmation:
            content.text = "Require “I'm Parked”"
            cell.accessoryView = makeSwitch(settings.requireParkedConfirmation) { AppSettings.shared.requireParkedConfirmation = $0 }
        case .parkedDelay:
            content.text = "Stand still for"
            content.secondaryText = "\(Int(settings.parkedConfirmationDelay)) s"
            let stepper = UIStepper()
            stepper.minimumValue = 5
            stepper.maximumValue = AppSettings.parkedDelayRange.upperBound
            stepper.stepValue = 5
            stepper.value = max(5, settings.parkedConfirmationDelay)
            stepper.addAction(UIAction { action in
                if let stepper = action.sender as? UIStepper {
                    AppSettings.shared.parkedConfirmationDelay = stepper.value
                }
            }, for: .valueChanged)
            cell.accessoryView = stepper
        case .audioContinues:
            content.text = "Keep sound while driving"
            cell.accessoryView = makeSwitch(settings.audioContinuesWhileDriving) { AppSettings.shared.audioContinuesWhileDriving = $0 }
        case .simulation:
            content.text = "Simulate CarPlay"
            cell.accessoryView = makeMenuButton(
                title: settings.drivingSimulation == .off ? "Off" : (settings.drivingSimulation == .stopped ? "Standing still" : "Driving"),
                options: DrivingSimulation.allCases.map { option in
                    (option.displayName, option == settings.drivingSimulation, { AppSettings.shared.drivingSimulation = option })
                }
            )
        case .searchEngine:
            content.text = "Search engine"
            cell.accessoryView = makeMenuButton(
                title: settings.searchEngine.displayName,
                options: SearchEngine.allCases.map { engine in
                    (engine.displayName, engine == settings.searchEngine, { AppSettings.shared.searchEngine = engine })
                }
            )
        case .desktopSites:
            content.text = "Request desktop sites"
            cell.accessoryView = makeSwitch(settings.prefersDesktopSites) { AppSettings.shared.prefersDesktopSites = $0 }
        case .carCompatibleVideo:
            content.text = "Car-compatible video"
            cell.accessoryView = makeSwitch(settings.carCompatibleVideo) { AppSettings.shared.carCompatibleVideo = $0 }
        case .locationPermission:
            content.text = "Location"
            content.secondaryText = describeLocation(monitor.locationAuthorization)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .motionPermission:
            content.text = "Motion & Fitness"
            content.secondaryText = describeMotion()
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .frameMirror:
            content.text = "Frames in CarPlay Now Playing"
            cell.accessoryView = makeSwitch(settings.nowPlayingFrameMirror) { AppSettings.shared.nowPlayingFrameMirror = $0 }
        case .capabilities:
            content.text = "What works on this install"
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .restoreBookmarks:
            content.text = "Restore default bookmarks"
            content.textProperties.color = .systemOrange
            cell.selectionStyle = .default
        case .version:
            content.text = "Version"
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "?"
            let build = info?["CFBundleVersion"] as? String ?? "?"
            content.secondaryText = "\(version) (\(build))"
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .locationPermission, .motionPermission:
            let monitor = DrivingStateMonitor.shared
            if monitor.locationAuthorization == .notDetermined || monitor.motionAuthorization == .notDetermined {
                monitor.requestPermissions()
            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .capabilities:
            navigationController?.pushViewController(CapabilitiesViewController(style: .insetGrouped), animated: true)
        case .restoreBookmarks:
            LibraryStore.shared.restoreDefaultBookmarks()
        default:
            break
        }
    }

    // MARK: - Helpers

    private func makeSwitch(_ isOn: Bool, onChange: @escaping (Bool) -> Void) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addAction(UIAction { action in
            if let toggle = action.sender as? UISwitch {
                onChange(toggle.isOn)
            }
        }, for: .valueChanged)
        return toggle
    }

    private func makeMenuButton(title: String, options: [(String, Bool, () -> Void)]) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: "chevron.up.chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let button = UIButton(configuration: configuration)
        button.menu = UIMenu(children: options.map { option in
            UIAction(title: option.0, state: option.1 ? .on : .off) { _ in option.2() }
        })
        button.showsMenuAsPrimaryAction = true
        button.sizeToFit()
        return button
    }

    private func describeLocation(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Tap to allow"
        case .denied, .restricted: return "Off: open Settings"
        case .authorizedWhenInUse: return "While using"
        case .authorizedAlways: return "Always"
        @unknown default: return "Unknown"
        }
    }

    private func describeMotion() -> String {
        switch DrivingStateMonitor.shared.motionAuthorization {
        case .notDetermined: return "Tap to allow"
        case .denied, .restricted: return "Off: open Settings"
        case .authorized: return "Allowed"
        @unknown default: return "Unknown"
        }
    }
}

