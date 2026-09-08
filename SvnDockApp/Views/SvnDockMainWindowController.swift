import AppKit
import SwiftUI

@MainActor
final class SvnDockMainWindowController: ObservableObject {
    static let sceneID = "main"
    weak var window: NSWindow?

    func show(using openWindow: OpenWindowAction) {
        if window == nil {
            openWindow(id: Self.sceneID)
        }
        showExistingWindow()
    }

    func showExistingWindow() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Keep a weak reference to the main window so menu actions reuse it without
/// confusing it with settings or a standalone diff window.
struct SvnDockMainWindowReader: NSViewRepresentable {
    let controller: SvnDockMainWindowController

    func makeNSView(context: Context) -> WindowReferenceView {
        let view = WindowReferenceView()
        view.controller = controller
        return view
    }

    func updateNSView(_ nsView: WindowReferenceView, context: Context) {
        nsView.controller = controller
        if let window = nsView.window { controller.window = window }
    }

    final class WindowReferenceView: NSView {
        weak var controller: SvnDockMainWindowController?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { controller?.window = window }
        }
    }
}
