// swift-tools-version:5.9
// Unit tests for DriveIn's platform-independent logic (parked-state rules, URL parsing,
// media classification, JavaScript call encoding). Runs on Linux and macOS:
//     swift test
// The iOS app itself is built from project.yml (XcodeGen); this package only reuses
// a few of its source files.
import PackageDescription

let package = Package(
    name: "DriveInCore",
    targets: [
        .target(
            name: "DriveInCore",
            path: "DriveIn",
            exclude: [
                "App",
                "Phone",
                "Player",
                "CarPlay",
                "Assets.xcassets",
                "Browser/BrowserTab.swift",
                "Browser/WebEnvironment.swift",
                "Core/CapabilityReport.swift",
                "Core/CarPlaySessionState.swift",
                "Core/DrivingStateMonitor.swift",
                "Core/ImageLoader.swift",
            ],
            sources: [
                "Core/AddressParser.swift",
                "Core/AppSettings.swift",
                "Core/LibraryStore.swift",
                "Core/MediaModels.swift",
                "Core/Notifications.swift",
                "Core/ParkedStateMachine.swift",
                "Browser/StartPage.swift",
                "Browser/WebScripts.swift",
            ]
        ),
        .testTarget(
            name: "DriveInCoreTests",
            dependencies: ["DriveInCore"],
            path: "Tests/DriveInCoreTests"
        ),
    ]
)
