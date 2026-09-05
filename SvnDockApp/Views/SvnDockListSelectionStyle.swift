import AppKit
import SwiftUI

extension View {
    /// Apply to a custom card inside a native List. The card draws selection;
    /// AppKit still owns selection, keyboard navigation, and accessibility.
    func svnDockCardSelection() -> some View {
        background {
            SvnDockListSelectionStyle()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct SvnDockListSelectionStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionStyleView {
        SelectionStyleView()
    }

    func updateNSView(_ nsView: SelectionStyleView, context: Context) {
        nsView.scheduleSelectionStyle()
    }

    final class SelectionStyleView: NSView {
        private var hasScheduledUpdate = false

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleSelectionStyle()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleSelectionStyle()
        }

        func scheduleSelectionStyle() {
            guard !hasScheduledUpdate else { return }
            hasScheduledUpdate = true
            // SwiftUI may finish attaching or updating the row after the
            // representable callback. Wait until its table delegate finishes
            // before changing AppKit drawing to avoid a reentrant update.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasScheduledUpdate = false
                self.applySelectionStyle()
            }
        }

        func applySelectionStyle() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                        table.needsDisplay = true
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
