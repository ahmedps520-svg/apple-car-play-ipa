import UIKit

/// Shows, for this exact install, which CarPlay paths work: official, conditional, or blocked
/// by a missing entitlement. Reads the embedded provisioning profile at runtime.
final class CapabilitiesViewController: UITableViewController {
    private var report = CapabilityReport.current()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "What works"
        if navigationController?.viewControllers.first === self {
            navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reloadReport), name: .drivingStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(reloadReport), name: .carPlaySessionDidChange, object: nil)
        center.addObserver(self, selector: #selector(reloadReport), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func reloadReport() {
        report = CapabilityReport.current()
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        report.sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        report.sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        report.sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        report.sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let row = report.sections[indexPath.section].rows[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.title
        content.secondaryText = row.detail
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        if let status = row.status {
            content.image = UIImage(systemName: status.symbol)
            content.imageProperties.tintColor = status.color
        }
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}
