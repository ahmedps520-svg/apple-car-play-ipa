import Foundation

extension Notification.Name {
    /// `DrivingStateMonitor.state` or `canConfirmParked` changed.
    static let drivingStateDidChange = Notification.Name("DriveIn.drivingStateDidChange")
    /// A `BrowserTab` changed URL, title, progress, navigation state or detected media.
    /// The notification object is the tab.
    static let browserTabDidChange = Notification.Name("DriveIn.browserTabDidChange")
    /// `MediaCatalog` gained or lost items.
    static let mediaCatalogDidChange = Notification.Name("DriveIn.mediaCatalogDidChange")
    /// `PlaybackController` started, paused, finished or changed what it is allowed to show.
    static let playbackStateDidChange = Notification.Name("DriveIn.playbackStateDidChange")
    /// Bookmarks or history changed.
    static let libraryDidChange = Notification.Name("DriveIn.libraryDidChange")
    /// A user setting changed.
    static let settingsDidChange = Notification.Name("DriveIn.settingsDidChange")
    /// A CarPlay scene connected or disconnected, or its session configuration changed.
    static let carPlaySessionDidChange = Notification.Name("DriveIn.carPlaySessionDidChange")
}
