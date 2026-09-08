import Foundation
import SvnDockCore

extension SvnDockStore {
    func beginTransferProgress(kind: SvnDockOperationKind, workingCopy: SvnDockWorkingCopy,
                               selectedItemCount: Int? = nil, totalWorkingCopies: Int = 1) -> UUID {
        let id = UUID()
        transferProgress.snapshot = SvnDockTransferProgress(operationID: id, kind: kind,
            phase: kind == .committing ? "正在检查提交内容…" : "正在准备更新…",
            selectedItemCount: selectedItemCount, workingCopyName: workingCopy.name,
            totalWorkingCopies: totalWorkingCopies, startedAt: .now)
        return id
    }

    func endTransferProgress(id: UUID) {
        guard transferProgress.snapshot?.operationID == id else { return }
        transferProgress.snapshot = nil
    }

    func selectTransferWorkingCopy(_ copy: SvnDockWorkingCopy, index: Int, id: UUID) {
        guard var value = transferProgress.snapshot, value.operationID == id else { return }
        value.workingCopyName = copy.name
        value.completedWorkingCopies = index
        value.processedItems = 0
        value.currentPath = nil
        value.phase = "正在准备更新…"
        transferProgress.snapshot = value
    }

    func completeTransferWorkingCopy(_ count: Int, id: UUID) {
        guard var value = transferProgress.snapshot, value.operationID == id else { return }
        value.completedWorkingCopies = count
        transferProgress.snapshot = value
    }

    func setTransferProgressPhase(_ phase: String, id: UUID) {
        guard var value = transferProgress.snapshot, value.operationID == id else { return }
        value.phase = phase
        transferProgress.snapshot = value
    }

    /// Consume cumulative snapshots through a one-element mailbox. Output
    /// threads never wait for UI work, and a large commit cannot enqueue one
    /// MainActor task per file. Finish/drain before advancing to verification.
    func withReportedTransferProgress(
        id: UUID,
        operation: (@escaping @Sendable (SVNProgressSnapshot) -> Void) async throws -> Void
    ) async throws {
        let (stream, continuation) = AsyncStream<SVNProgressSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                self?.applyTransferReport(snapshot, id: id)
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { break }
            }
        }
        let result: Result<Void, Error>
        do {
            try await operation { continuation.yield($0) }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        continuation.finish()
        await consumer.value
        try result.get()
    }

    private func applyTransferReport(_ report: SVNProgressSnapshot, id: UUID) {
        guard var value = transferProgress.snapshot, value.operationID == id else { return }
        value.processedItems = max(value.processedItems, report.processedItemCount)
        value.currentPath = report.currentPath
        switch report.phase {
        case .preparing:
            value.phase = value.kind == .committing ? "正在检查提交内容…" : "正在准备更新…"
        case .processing:
            value.phase = value.kind == .committing ? "正在提交文件…" : "正在应用更新…"
        case .transferring:
            value.phase = value.kind == .committing ? "正在传输文件内容…" : "正在接收文件内容…"
        case .awaitingServer:
            value.phase = value.kind == .committing ? "等待仓库确认…" : "正在完成更新…"
        }
        if value != transferProgress.snapshot { transferProgress.snapshot = value }
    }
}
