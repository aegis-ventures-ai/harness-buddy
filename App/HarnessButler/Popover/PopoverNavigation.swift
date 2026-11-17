import Foundation
import Observation

/// Which popover page is showing. Shared so other parts of the app (an update notification, H-6)
/// can open the popover on a given page.
@Observable
final class PopoverNavigation {
    enum Page: Hashable { case usage, harnesses }

    var page: Page = PopoverNavigation.initialPage
    /// The subscription whose detail page is open.
    var selection: UUID?

    func show(_ page: Page) {
        self.page = page
        selection = nil
    }

    private static var initialPage: Page {
        #if DEBUG
        // `--open-popover harnesses` opens on the harnesses page (UI checks).
        if let index = CommandLine.arguments.firstIndex(of: "--open-popover"),
           CommandLine.arguments.dropFirst(index + 1).first == "harnesses" { return .harnesses }
        #endif
        return .usage
    }
}
