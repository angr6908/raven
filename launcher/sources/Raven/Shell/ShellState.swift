import SwiftUI

@Observable
final class ShellState {
    var columnVisibility: NavigationSplitViewVisibility = .all
    var inspectorShown = true
}
