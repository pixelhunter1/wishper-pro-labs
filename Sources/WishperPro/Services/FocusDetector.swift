import AppKit
import ApplicationServices

/// Where a dictation will be pasted.
struct DictationTarget: Sendable, Equatable {
    /// `app:<bundle ID>` or `site:<host>`.
    let key: String
    /// The app name, or the host for a site.
    let displayName: String
    /// Sent to the cleanup model; for a site, the browser's name (the host stays on this Mac).
    let appName: String
}

/// Finds the app (and, in a browser, the site) that will receive the text.
enum FocusDetector {
    /// Longest wait for each Accessibility request to the browser.
    private static let messagingTimeout: Float = 0.25
    /// Stops the search in very large windows.
    private static let maxVisitedElements = 400

    /// Reads the frontmost app now; the page host is read in the background.
    @MainActor
    static func capture() -> Task<DictationTarget, Never> {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? ""
        let appName = app?.localizedName ?? "App"
        let pid = app?.processIdentifier ?? 0
        let family = StyleCatalog.browsers[bundleID]
        return Task.detached(priority: .userInitiated) {
            var host: String?
            if let family, pid > 0, AXIsProcessTrusted() {
                host = pageAddress(pid: pid, family: family).flatMap(host(fromAddress:))
            }
            return DictationTarget(
                key: StyleCatalog.key(bundleID: bundleID, host: host),
                displayName: host ?? appName,
                appName: appName
            )
        }
    }

    /// "https://www.mail.google.com/mail/u/0" → "mail.google.com". Internal pages and search text give `nil`.
    nonisolated static func host(fromAddress address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(),
              host.contains(".")
        else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    /// Safari exposes the page URL on its web area; Chromium and Firefox show it in the address field.
    private nonisolated static func pageAddress(pid: pid_t, family: StyleCatalog.BrowserFamily) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        switch family {
        case .safari:
            guard let webArea = firstDescendant(of: window, role: "AXWebArea"),
                  let url = attribute(webArea, kAXURLAttribute)
            else { return nil }
            return (url as? URL)?.absoluteString
        case .chromium, .firefox:
            guard let field = firstDescendant(of: window, role: kAXTextFieldRole) else { return nil }
            return attribute(field, kAXValueAttribute) as? String
        }
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// Breadth-first, so browser chrome (address bar) is found before page content; web content is not entered.
    private nonisolated static func firstDescendant(of root: AXUIElement, role wanted: String) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < maxVisitedElements {
            let current = queue.removeFirst()
            visited += 1
            guard let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children {
                let role = attribute(child, kAXRoleAttribute) as? String
                if role == wanted {
                    return child
                }
                if role != "AXWebArea" {
                    queue.append(child)
                }
            }
        }
        return nil
    }
}
