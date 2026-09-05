import Foundation
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum OperationRecordRegressionChecks {
    static func run() throws {
        let copy = SvnDockWorkingCopy(name: "fixture", rootURL: URL(fileURLWithPath: "/tmp/operation-record-fixture"))
        let start = Date(timeIntervalSince1970: 100)
        let finish = Date(timeIntervalSince1970: 110)
        let uncertain = SvnDockOperationRecord(
            workingCopy: copy, actionTitle: "提交", startedAt: start, finishedAt: finish,
            outcome: .uncertain, summary: "连接中断，结果待确认", detail: "请检查历史和本地状态。"
        )
        try check(uncertain.workingCopyID == copy.id && uncertain.workingCopyName == copy.name,
                  "records preserve the exact working-copy identity")
        try check(uncertain.outcome == .uncertain && uncertain.outcome.displayName == "结果待确认",
                  "an uncertain executor result must never be presented as success or rollback")
        try check(uncertain.copyText.contains("结果：结果待确认")
                  && uncertain.copyText.contains(uncertain.summary)
                  && uncertain.copyText.contains("请检查历史和本地状态。")
                  && uncertain.copyText.contains(start.formatted(.iso8601))
                  && uncertain.copyText.contains(finish.formatted(.iso8601)),
                  "copied details include the explicit outcome, summary, guidance and both timestamps")

        var records: [SvnDockOperationRecord] = []
        for index in 0..<40 {
            let record = SvnDockOperationRecord(
                workingCopy: copy, actionTitle: "更新", startedAt: start,
                finishedAt: finish.addingTimeInterval(Double(index)),
                outcome: .success, summary: "completion \(index)"
            )
            records = SvnDockOperationRecord.prepending(record, to: records)
        }
        try check(records.count == 30 && records.first?.summary == "completion 39"
                  && records.last?.summary == "completion 10", "history retains only the 30 most recent completions")
        let replaced = SvnDockOperationRecord(
            id: records[5].id, workingCopy: copy, actionTitle: "更新", startedAt: start,
            finishedAt: finish, outcome: .failure, summary: "confirmed failure"
        )
        records = SvnDockOperationRecord.prepending(replaced, to: records)
        try check(records.count == 30 && records.first == replaced
                  && records.filter { $0.id == replaced.id }.count == 1,
                  "a reconciled result replaces its old ID without taking another history slot")
        try check(!records[0].copyText.contains("nil"), "missing optional detail produces no placeholder in copied results")

        let sensitive = SvnDockOperationRecord(
            workingCopy: copy, actionTitle: "提交", startedAt: start, finishedAt: finish,
            outcome: .failure, summary: "连接失败",
            detail: #"""
            Unable to access https://alice:p%40ssword@svn.example.test/project
            svn+ssh://developer@svn.example.test/branch
            https://svn.example.test/path?token=query-secret&revision=12&access_token=second-secret
            password=plain-secret; passwd: 'secret with spaces'
            {"api_key": "json-secret", "token": "escaped\"secret", "revision": 12}
            --password "cli secret" --token=cli-token --passwd cli-passwd
            Authorization: Bearer bearer-secret
            authorization=Basic basic-secret
            --authorization Negotiate negotiate-secret
            {"authorization": "Bearer json-bearer-secret"}
            ordinary diagnostic: E170013; password_policy=strict; access_token_count=2
            """#
        )
        for secret in ["alice", "p%40ssword", "developer", "query-secret", "second-secret", "plain-secret",
                       "secret with spaces", "json-secret", "escaped", "cli secret", "cli-token", "cli-passwd",
                       "bearer-secret", "basic-secret", "negotiate-secret", "json-bearer-secret"] {
            try check(sensitive.detail?.contains(secret) == false && !sensitive.copyText.contains(secret),
                      "sensitive URL authority and parameter values are removed before display and copying: \(secret)")
        }
        try check(sensitive.detail?.contains("https://[已隐藏]@svn.example.test/project") == true
                  && sensitive.detail?.contains("revision=12") == true
                  && sensitive.detail?.contains("E170013") == true
                  && sensitive.detail?.contains("password_policy=strict") == true
                  && sensitive.detail?.contains("access_token_count=2") == true,
                  "redaction preserves useful hosts, paths, errors and unrelated parameter names")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw OperationRecordCheckFailure(message: message) }
    }
}

private struct OperationRecordCheckFailure: Error { let message: String }
