import AppKit
import Foundation

// Read-only preflight: do not change the user's display, accessibility settings,
// running applications, preferences, or installed-app registration.
let screen = NSScreen.main
let environment: [String: Any] = [
    "osMajor": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
    "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
    "screenWidth": screen?.visibleFrame.width ?? 0,
    "screenHeight": screen?.visibleFrame.height ?? 0,
    "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
    "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
    "runningLocus": NSRunningApplication.runningApplications(
        withBundleIdentifier: "io.sparktales.locus"
    ).filter { !$0.isTerminated }.map { [
        "pid": String($0.processIdentifier), "path": $0.bundleURL?.path ?? "unknown"
    ] }
]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys]))
