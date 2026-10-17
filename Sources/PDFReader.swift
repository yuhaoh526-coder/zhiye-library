import SwiftUI
import PDFKit

struct PDFReader: NSViewRepresentable {
    let url: URL
    let initialPage: Int
    let onPageChange: (Int) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor.windowBackgroundColor
        view.minScaleFactor = 0.15
        view.maxScaleFactor = 5
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.loadedURL != url else { return }
        coordinator.loading = true
        coordinator.onPageChange = onPageChange
        coordinator.loadedURL = url
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            view.document = nil
            coordinator.loading = false
            DispatchQueue.main.async { onFailure("无法打开这个 PDF。文件可能已移动、损坏或加密。") }
            return
        }
        view.document = document
        let page = max(0, min(initialPage, document.pageCount - 1))
        // Wait until AppKit has laid out the new document before restoring its page.
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator, coordinator.loadedURL == url else { return }
            view.layoutSubtreeIfNeeded()
            if let target = document.page(at: page) { view.go(to: target) }
            coordinator.loading = false
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator {
        var loadedURL: URL?
        var loading = false
        var onPageChange: ((Int) -> Void)?
        var observer: NSObjectProtocol?
        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                guard let self, !self.loading, let view, let document = view.document, let page = view.currentPage else { return }
                self.onPageChange?(document.index(for: page))
            }
        }
        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        deinit { stopObserving() }
    }
}
