/*
 * Copyright (C) 2026 Kenzi Voyer.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if DEBUG && os(macOS)

import AppKit

/// Saves the app's windows as PNG files, drawn by the app itself, so the Mac layout can be checked and screenshots
/// taken without the Screen Recording permission.
///
/// Launch with `-SnapshotDelay <seconds>`. After the delay every visible window is saved to `Snapshots` in the app's
/// temporary directory, named after the window's title, and the app quits if `-SnapshotQuit YES` is passed too.
/// `-SnapshotWindowSize <width>x<height>` resizes the windows first, in points.
///
/// The system's glass materials, e.g. the sidebar's, aren't drawn this way, so the UI test in
/// `AuthenticatorUITests/MacScreenshotTests.swift` takes the real screenshots.
enum WindowSnapshots {

    /// `-DemoAppearance light` or `dark`, so screenshots don't depend on the system setting.
    static func applyDemoAppearance() {
        switch UserDefaults.standard.string(forKey: "DemoAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    /// `-DemoWindowSize <width>x<height>` gives the main window that size, in points including the title bar, e.g.
    /// 1280x800 for Mac App Store screenshots at 2560 × 1600 pixels.
    static func resizeMainWindowIfRequested() {
        guard let size = UserDefaults.standard.string(forKey: "DemoWindowSize").flatMap(parseSize) else { return }
        Task {
            for _ in 0..<50 {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == AppWindow.main && $0.isVisible }) {
                    var frame = window.frame
                    frame.origin.y += frame.height - size.height
                    frame.size = size
                    window.setFrame(frame, display: true)
                    window.center()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    static func scheduleIfRequested() {
        let defaults = UserDefaults.standard
        let delay = defaults.double(forKey: "SnapshotDelay")
        guard delay > 0 else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if let size = defaults.string(forKey: "SnapshotWindowSize").flatMap(parseSize) {
                for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                    window.setContentSize(size)
                }
                try? await Task.sleep(for: .seconds(1))
            }
            save()
            if defaults.bool(forKey: "SnapshotQuit") {
                NSApp.terminate(nil)
            }
        }
    }

    static func save() {
        let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "Snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            // The frame view, so the title bar and toolbar are included.
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let title = window.title.isEmpty ? "window-\(index)" : window.title
            let url = directory.appending(path: "\(title.replacingOccurrences(of: "/", with: "-")).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private static func parseSize(_ string: String) -> CGSize? {
        let parts = string.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
}

#endif
