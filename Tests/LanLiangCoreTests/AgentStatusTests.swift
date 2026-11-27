import XCTest
@testable import LanLiangCore

/// 内存文件系统：统计列目录、打开次数和读取字节数（契约 0.4.0 §5 A9）。
final class MemFS: AgentFileSystem {
    var files: [String: (data: Data, mtime: Date)] = [:]
    /// 创建时间：第一次写入的时间（0.4.1 分辨启动后才出现的文件）。
    var created: [String: Date] = [:]
    var dirs: Set<String> = []
    var listed: [String] = []
    var opens: [String] = []
    var maxRead = 0
    var bytesRead = 0

    func mkdir(_ p: String) {
        var cur = p
        while cur.count > 1 { dirs.insert(cur); cur = (cur as NSString).deletingLastPathComponent }
    }
    func write(_ p: String, _ s: String, mtime: Date) {
        mkdir((p as NSString).deletingLastPathComponent)
        if files[p] == nil { created[p] = mtime }
        files[p] = (Data(s.utf8), mtime)
    }
    func append(_ p: String, _ s: String, mtime: Date) {
        if let f = files[p] { files[p] = (f.data + Data(s.utf8), mtime) } else { write(p, s, mtime: mtime) }
    }
    func list(_ dir: String) -> [String]? {
        listed.append(dir)
        guard dirs.contains(dir) else { return nil }
        let kids = files.keys.map { $0 } + Array(dirs)
        return Array(Set(kids.filter { ($0 as NSString).deletingLastPathComponent == dir }
            .map { ($0 as NSString).lastPathComponent }))
    }
    func info(_ path: String) -> AgentFileInfo? {
        if let f = files[path] { return AgentFileInfo(size: UInt64(f.data.count), mtime: f.mtime, isDirectory: false, created: created[path]) }
        if dirs.contains(path) { return AgentFileInfo(size: 0, mtime: .distantPast, isDirectory: true) }
        return nil
    }
    func read(_ path: String, offset: UInt64, length: Int) -> Data? {
        opens.append(path)
        guard let f = files[path], offset <= UInt64(f.data.count) else { return nil }
        let start = Int(offset), end = min(f.data.count, start + length)
        maxRead = max(maxRead, end - start)
        bytesRead += end - start
        return f.data.subdata(in: start..<end)
    }
}

final class AgentStatusTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_796_198_400) // 2026-12-01 08:00 UTC 左右，只当基准
    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    let croot = "/h/.codex/sessions"
    let aroot = "/h/.gemini/antigravity/brain"

    func dayDir(_ d: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: d)
        return croot + String(format: "/%04d/%02d/%02d", c.year!, c.month!, c.day!)
    }
    func ev(_ type: String) -> String { "{\"timestamp\":\"2026-11-27T08:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"}}\n" }
    func ask(_ id: String, name: String = "request_user_input_async") -> String {
        "{\"timestamp\":\"2026-11-27T08:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"\(name)\",\"arguments\":\"{\\\"q\\\":\\\"SECRET_ARGS\\\"}\",\"call_id\":\"\(id)\"}}\n"
    }
    func out(_ id: String) -> String {
        "{\"timestamp\":\"2026-11-27T08:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"\(id)\",\"output\":\"SECRET_OUTPUT\"}}\n"
    }
    /// 带 tool_calls 的中间步骤（0.4.1：工作中；status=ERROR 为出错）。
    func st(_ s: String) -> String { "{\"type\":\"PLANNER_RESPONSE\",\"status\":\"\(s)\",\"source\":\"MODEL\",\"step_index\":1,\"tool_calls\":[{}]}\n" }
    /// 一行 Antigravity 记录（只有字段名，没有正文）。
    func rec(_ type: String, status: String = "DONE", source: String = "MODEL", tools: String? = nil) -> String {
        "{\"type\":\"\(type)\",\"status\":\"\(status)\",\"source\":\"\(source)\",\"created_at\":\"2026-11-27T09:00:00Z\",\"step_index\":1" + (tools.map { ",\"tool_calls\":\($0)" } ?? "") + "}\n"
    }
    /// 最终回复：不带 tool_calls 的 PLANNER_RESPONSE。
    var fin: String { rec("PLANNER_RESPONSE") }
    var fixtureDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/agent-status")
    }
    /// 老板 Mac 上 09:15:04–09:18:40 的真实序列（step 20–49）：(step, 距第一行秒数, 行)。
    func realSequence() throws -> [(step: Int, offset: TimeInterval, line: String)] {
        let text = try String(contentsOf: fixtureDir.appendingPathComponent("antigravity-real.jsonl"))
        var out: [(step: Int, offset: TimeInterval, line: String)] = []
        var first: Date?
        for l in text.split(separator: "\n") {
            let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any])
            let d = try XCTUnwrap(ISO8601DateFormatter().date(from: o["created_at"] as! String))
            if first == nil { first = d }
            out.append((step: o["step_index"] as! Int, offset: d.timeIntervalSince(first!), line: String(l) + "\n"))
        }
        return out
    }

    func codex(_ fs: MemFS) -> AgentSessionReader { AgentSessionReader(tool: .codex, root: croot, fs: fs, calendar: utc) }
    func ag(_ fs: MemFS) -> AgentSessionReader { AgentSessionReader(tool: .antigravity, root: aroot, fs: fs, calendar: utc) }

    /// 追加一行并通知读取器。
    func push(_ r: AgentSessionReader, _ fs: MemFS, _ p: String, _ s: String, at t: Date) {
        fs.append(p, s, mtime: t)
        while r.fileChanged(p, now: t) {}
    }

    // A1
    func testCodexEvents() {
        let fs = MemFS(); let r = codex(fs); let p = dayDir(t0) + "/rollout-a.jsonl"
        fs.mkdir(dayDir(t0)); r.start(now: t0)
        push(r, fs, p, ev("task_started"), at: t0)
        XCTAssertEqual(r.status(now: t0).phase, .working)
        push(r, fs, p, ev("task_complete"), at: t0 + 1)
        XCTAssertEqual(r.status(now: t0 + 1).phase, .done)
        push(r, fs, p, ev("task_started"), at: t0 + 2)
        push(r, fs, p, ev("turn_aborted"), at: t0 + 3)
        XCTAssertEqual(r.status(now: t0 + 3).phase, .failed)
        XCTAssertEqual(AgentStatusText.text(r.status(now: t0 + 3), tool: .codex, now: t0 + 3), "已中断")
    }

    // 0.4.1 §D1：真实序列逐行断言
    func testV041RealSequence() throws {
        let seq = try realSequence()
        XCTAssertEqual(seq.map { $0.step }, Array(20...49))
        let fs = MemFS(); let r = ag(fs); let p = aroot + "/s/.system_generated/logs/transcript.jsonl"
        fs.mkdir(aroot); r.start(now: t0)
        for (step, off, line) in seq {
            // 两行之间（包括 09:15:08→09:15:25 停 17 秒）：上一步是工作中就一直是工作中
            if step != 20 && step != 33 { XCTAssertNotEqual(r.status(now: t0 + off - 0.5).phase, .idle, "before \(step)") }
            push(r, fs, p, line, at: t0 + off)
            let want: AgentPhase = step == 32 ? .done : .working
            XCTAssertEqual(r.status(now: t0 + off).phase, want, "step \(step)")
        }
        XCTAssertEqual(r.status(now: t0 + 20).phase, .working) // 17 秒停顿中间
        // 一轮中途 AgentDotStyle 不变：刚完成之后 USER_INPUT 立刻回到工作中，前面已逐行断言
    }

    // 0.4.1 §D2：做到一半启动栏量（step 35–49，没有 USER_INPUT）
    func testV041StartMidTurn() throws {
        let tail = try realSequence().filter { $0.step >= 35 }.map { $0.line }.joined()
        let now = t0
        let fs = MemFS(); fs.write(aroot + "/s/.system_generated/logs/transcript.jsonl", tail, mtime: now - 10)
        let r = ag(fs); r.start(now: now)
        XCTAssertEqual(r.status(now: now).phase, .working)
        XCTAssertEqual(r.status(now: now).since, now - 10)
        let f2 = MemFS(); f2.write(aroot + "/s/.system_generated/logs/transcript.jsonl", tail, mtime: now - 660)
        let r2 = ag(f2); r2.start(now: now)
        XCTAssertEqual(r2.status(now: now).phase, .idle)
    }

    // 0.4.1 §D3：启动时最后一行是结束记录；出错不补显示
    func testV041StartAfterFinal() throws {
        let body = try realSequence().filter { $0.step >= 40 }.map { $0.line }.joined()
        let now = t0
        let p = aroot + "/s/.system_generated/logs/transcript.jsonl"
        let fs = MemFS(); fs.write(p, body + fin + "not json\n", mtime: now - 30)
        let r = ag(fs); r.start(now: now)
        XCTAssertEqual(r.status(now: now).phase, .done)
        XCTAssertEqual(r.status(now: now + 29).phase, .done)
        XCTAssertEqual(r.status(now: now + 30).phase, .idle)
        let f2 = MemFS(); f2.write(p, body + fin, mtime: now - 90)
        let r2 = ag(f2); r2.start(now: now)
        XCTAssertEqual(r2.status(now: now).phase, .idle)
        let f3 = MemFS(); f3.write(p, body + rec("ERROR_MESSAGE", source: "SYSTEM"), mtime: now - 5)
        let r3 = ag(f3); r3.start(now: now)
        XCTAssertEqual(r3.status(now: now).phase, .idle)
    }

    // 0.4.1 §D4：刚完成后被后台任务唤醒
    func testV041WokenAfterFinal() {
        let fs = MemFS(); let r = ag(fs); let p = aroot + "/x/transcript.jsonl"
        push(r, fs, p, rec("USER_INPUT", source: "USER_EXPLICIT") + st("DONE"), at: t0)
        push(r, fs, p, fin, at: t0 + 1)
        XCTAssertEqual(r.status(now: t0 + 1).phase, .done)
        push(r, fs, p, rec("SYSTEM_MESSAGE", source: "SYSTEM"), at: t0 + 5)
        XCTAssertEqual(r.status(now: t0 + 5).phase, .working)
        push(r, fs, p, fin, at: t0 + 10)
        XCTAssertEqual(r.status(now: t0 + 10).phase, .done)
        XCTAssertEqual(r.status(now: t0 + 70).phase, .idle)
        push(r, fs, p, rec("SYSTEM_MESSAGE", source: "SYSTEM"), at: t0 + 10 + 1800)
        XCTAssertEqual(r.status(now: t0 + 10 + 1800).phase, .working)
    }

    // 0.4.1 §D5：出错
    func testV041Errors() {
        for line in [rec("ERROR_MESSAGE", status: "DONE", source: "SYSTEM"), rec("GENERIC", status: "ERROR")] {
            let fs = MemFS(); let r = ag(fs); let p = aroot + "/x/transcript.jsonl"
            push(r, fs, p, st("DONE"), at: t0)
            push(r, fs, p, line, at: t0 + 1)
            XCTAssertEqual(r.status(now: t0 + 1).phase, .failed, line)
            XCTAssertEqual(AgentStatusText.text(r.status(now: t0 + 1), tool: .antigravity, now: t0 + 1), "出错")
            XCTAssertEqual(r.status(now: t0 + 60.9).phase, .failed)
            XCTAssertEqual(r.status(now: t0 + 61).phase, .idle)
            // 出错之后再来新行照表走
            push(r, fs, p, st("DONE"), at: t0 + 70)
            XCTAssertEqual(r.status(now: t0 + 70).phase, .working)
        }
    }

    // 0.4.1 §D6/§D7：CHECKPOINT、tool_calls 为空数组都是结束记录
    func testV041EndRecords() {
        for end in [rec("CHECKPOINT"), rec("PLANNER_RESPONSE", tools: "[]"), rec("PLANNER_RESPONSE", tools: "null"), fin] {
            let fs = MemFS(); let r = ag(fs); let p = aroot + "/x/transcript.jsonl"
            push(r, fs, p, rec("USER_INPUT", source: "USER_EXPLICIT") + rec("PLANNER_RESPONSE", tools: "[{}]"), at: t0)
            XCTAssertEqual(r.status(now: t0).phase, .working)
            push(r, fs, p, end, at: t0 + 1)
            XCTAssertEqual(r.status(now: t0 + 1).phase, .done, end)
            XCTAssertEqual(r.status(now: t0 + 61).phase, .idle)
        }
        // 深一层的位置也认
        let r = ag(MemFS())
        XCTAssertTrue(r.accepts(aroot + "/y/.system_generated/logs/transcript.jsonl"))
        XCTAssertFalse(r.accepts(aroot + "/y/other.jsonl"))
    }

    // 0.4.1 §D8：中途打断靠 10 分钟兜底；坏行也重置计时；超长行算工作中
    func testV041Interrupted() {
        let fs = MemFS(); let r = ag(fs); let p = aroot + "/x/transcript.jsonl"
        push(r, fs, p, rec("USER_INPUT", source: "USER_EXPLICIT") + st("DONE"), at: t0)
        XCTAssertEqual(r.status(now: t0 + 599).phase, .working)
        XCTAssertEqual(r.status(now: t0 + 600).phase, .idle)
        let f2 = MemFS(); let r2 = ag(f2)
        push(r2, f2, p, st("DONE"), at: t0)
        push(r2, f2, p, rec("GENERIC"), at: t0 + 599)
        XCTAssertEqual(r2.status(now: t0 + 599 + 599).phase, .working)
        push(r2, f2, p, "{bad json\n", at: t0 + 1198)
        XCTAssertEqual(r2.status(now: t0 + 1198 + 599).phase, .working)
        XCTAssertEqual(r2.status(now: t0 + 1198 + 600).phase, .idle)
        let huge = "{\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"x\":\"" + String(repeating: "a", count: 70_000) + "\"}\n"
        let f3 = MemFS(); let r3 = ag(f3)
        push(r3, f3, p, huge, at: t0)
        XCTAssertEqual(r3.status(now: t0).phase, .working)
    }

    // 0.4.1 §D10：Codex 启动后新出现的文件从头读
    func testV041CodexNewFileFromStart() {
        let fs = MemFS(); let r = codex(fs); let p = dayDir(t0) + "/rollout-new.jsonl"
        fs.mkdir(dayDir(t0)); r.start(now: t0)
        let meta = "{\"timestamp\":\"2026-11-27T08:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"x\",\"base\":\"" + String(repeating: "m", count: 28_000) + "\"}}\n"
        fs.write(p, meta + ev("task_started"), mtime: t0 + 1)
        let big = "{\"timestamp\":\"2026-11-27T08:00:04Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\",\"x\":\"" + String(repeating: "r", count: 70_000) + "\"}}\n"
        fs.append(p, big + String(repeating: ev("token_count"), count: 500), mtime: t0 + 5)
        XCTAssertGreaterThan(fs.files[p]!.data.count, 28_000 + 110_000)
        // FSEvents 合并成一次：第二次写入之后才第一次读
        while r.fileChanged(p, now: t0 + 5) {}
        XCTAssertEqual(r.status(now: t0 + 5).phase, .working)
        XCTAssertLessThanOrEqual(fs.maxRead, 1024 * 1024)
        // 分两次通知也一样，不因第二次写入丢失
        let f2 = MemFS(); let r2 = codex(f2)
        f2.mkdir(dayDir(t0)); r2.start(now: t0)
        push(r2, f2, p, meta + ev("task_started"), at: t0 + 1)
        XCTAssertEqual(r2.status(now: t0 + 1).phase, .working)
        push(r2, f2, p, big + String(repeating: ev("token_count"), count: 500), at: t0 + 5)
        XCTAssertEqual(r2.status(now: t0 + 5).phase, .working)
    }

    // 0.4.1 §D11：启动时已存在的文件仍只读末尾 64KB
    func testV041CodexExistingFileTailOnly() {
        let fs = MemFS(); let p = dayDir(t0) + "/rollout-old.jsonl"
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"x\":\"" + String(repeating: "m", count: 28_000) + "\"}}\n"
        fs.write(p, meta + ev("task_started") + String(repeating: ev("token_count"), count: 1500), mtime: t0 - 5)
        let r = codex(fs); r.start(now: t0)
        XCTAssertLessThanOrEqual(fs.maxRead, 64 * 1024)
        XCTAssertEqual(r.status(now: t0).phase, .idle) // task_started 不在末尾 64KB 里
        // 启动前就有、启动时没打开的文件之后变了：仍只读末尾
        let f2 = MemFS(); let q = dayDir(t0 - 3 * 86400) + "/rollout-older.jsonl"
        f2.write(q, meta + ev("task_started") + String(repeating: ev("token_count"), count: 1500), mtime: t0 - 3 * 86400)
        let r2 = codex(f2); r2.start(now: t0)
        f2.append(q, ev("token_count"), mtime: t0 + 1)
        r2.fileChanged(q, now: t0 + 1)
        XCTAssertLessThanOrEqual(f2.maxRead, 64 * 1024)
    }

    // A3
    func testUnknownEventsIgnored() {
        let fs = MemFS(); let r = codex(fs); let p = dayDir(t0) + "/rollout-a.jsonl"
        push(r, fs, p, ev("task_started"), at: t0)
        push(r, fs, p, ev("some_future_event"), at: t0 + 1)
        push(r, fs, p, "{\"timestamp\":\"x\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"shell\",\"call_id\":\"c9\"}}\n", at: t0 + 2)
        push(r, fs, p, "{\"type\":\"turn_context\",\"payload\":{\"type\":\"task_complete\"}}\n", at: t0 + 3)
        XCTAssertEqual(r.status(now: t0 + 3).phase, .working)
        let fa = MemFS(); let a = ag(fa); let q = aroot + "/x/transcript.jsonl"
        push(a, fa, q, st("RUNNING"), at: t0)
        push(a, fa, q, st("NEW_STATUS"), at: t0 + 1)
        push(a, fa, q, "{\"type\":\"X\"}\n", at: t0 + 2)
        push(a, fa, q, "{\"status\":7}\n", at: t0 + 3)
        XCTAssertEqual(a.status(now: t0 + 3).phase, .working)
    }

    // A3a
    func testAskingUser() {
        for name in ["request_user_input_async", "request_user_input"] {
            let fs = MemFS(); let r = codex(fs); let p = dayDir(t0) + "/rollout-a.jsonl"
            push(r, fs, p, ev("task_started"), at: t0)
            push(r, fs, p, ask("c1", name: name), at: t0 + 1)
            XCTAssertEqual(r.status(now: t0 + 1).phase, .asking, name)
            push(r, fs, p, out("other"), at: t0 + 2)
            XCTAssertEqual(r.status(now: t0 + 2).phase, .asking)
            // 10 分钟没有新行仍是问你问题
            XCTAssertEqual(r.status(now: t0 + 700).phase, .asking)
            push(r, fs, p, out("c1"), at: t0 + 710)
            XCTAssertEqual(r.status(now: t0 + 710).phase, .working)
            // 回到工作中后重新按 10 分钟计时
            XCTAssertEqual(r.status(now: t0 + 710 + 599).phase, .working)
            XCTAssertEqual(r.status(now: t0 + 710 + 600).phase, .idle)
        }
        // 同时记多个 call_id
        let fs = MemFS(); let r = codex(fs); let p = dayDir(t0) + "/rollout-a.jsonl"
        push(r, fs, p, ev("task_started"), at: t0)
        push(r, fs, p, ask("c1") + ask("c2"), at: t0 + 1)
        push(r, fs, p, out("c1"), at: t0 + 2)
        XCTAssertEqual(r.status(now: t0 + 2).phase, .asking)
        push(r, fs, p, out("c2"), at: t0 + 3)
        XCTAssertEqual(r.status(now: t0 + 3).phase, .working)
        // 提问后 task_complete / turn_aborted
        push(r, fs, p, ask("c3"), at: t0 + 4)
        push(r, fs, p, ev("task_complete"), at: t0 + 5)
        XCTAssertEqual(r.status(now: t0 + 5).phase, .done)
        push(r, fs, p, ev("task_started") + ask("c4"), at: t0 + 6)
        push(r, fs, p, ev("turn_aborted"), at: t0 + 7)
        XCTAssertEqual(r.status(now: t0 + 7).phase, .failed)
        XCTAssertTrue(r.sessions.values.allSatisfy { $0.pending.isEmpty })
        XCTAssertEqual(AgentStatusText.text(AgentToolStatus(phase: .asking), tool: .codex, now: t0), "问你问题")
    }

    func testLongOutputLineEndsAsk() {
        let fs = MemFS(); let r = codex(fs); let p = dayDir(t0) + "/rollout-a.jsonl"
        push(r, fs, p, ev("task_started") + ask("call_long"), at: t0)
        XCTAssertEqual(r.status(now: t0).phase, .asking)
        let big = String(repeating: "SECRET_OUTPUT ", count: 10_000) // > 64KB
        let line = "{\"timestamp\":\"2026-11-27T08:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"call_long\",\"output\":\"\(big)\"}}\n"
        XCTAssertGreaterThan(line.utf8.count, 64 * 1024)
        // 分两次写：先写一半（没有换行），再写完
        let half = line.utf8.count / 2
        let a = String(decoding: Array(line.utf8)[0..<half], as: UTF8.self)
        let b = String(decoding: Array(line.utf8)[half...], as: UTF8.self)
        push(r, fs, p, a, at: t0 + 1)
        XCTAssertEqual(r.status(now: t0 + 1).phase, .working)
        push(r, fs, p, b, at: t0 + 2)
        XCTAssertEqual(r.status(now: t0 + 2).phase, .working)
        push(r, fs, p, ev("task_complete"), at: t0 + 3)
        XCTAssertEqual(r.status(now: t0 + 3).phase, .done)
        // 长行里没有记下的 call_id：不结束
        let fs2 = MemFS(); let r2 = codex(fs2)
        push(r2, fs2, p, ev("task_started") + ask("c1"), at: t0)
        push(r2, fs2, p, line, at: t0 + 1)
        XCTAssertEqual(r2.status(now: t0 + 1).phase, .asking)
    }

    // A3b
    func testAskingThirtyMinuteFallback() {
        let fs = MemFS(); let r = codex(fs); let p = dayDir(t0) + "/rollout-a.jsonl"
        push(r, fs, p, ev("task_started") + ask("c1"), at: t0)
        XCTAssertEqual(r.nextDeadline(), t0 + 1800)
        XCTAssertEqual(r.status(now: t0 + 1799).phase, .asking)
        XCTAssertEqual(r.status(now: t0 + 1800).phase, .idle)
        XCTAssertNil(r.nextDeadline())
    }

    // A4
    func testBadLinesSkipped() {
        let fs = MemFS(); let r = codex(fs); let p = dayDir(t0) + "/rollout-a.jsonl"
        let huge = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"x\":\"" + String(repeating: "a", count: 70_000) + "\"}}\n"
        push(r, fs, p, "not json\n\n{\"type\":\"event_msg\",\"payload\":\"str\"}\n{\"type\":\"event_msg\",\"payload\":{\"type\":5}}\n\u{FF}\u{FE}event_msg\n" + huge, at: t0)
        XCTAssertEqual(r.status(now: t0).phase, .idle)
        push(r, fs, p, ev("task_started"), at: t0 + 1)
        XCTAssertEqual(r.status(now: t0 + 1).phase, .working)
        var bin = Data("{\"type\":\"event_msg\"".utf8); bin.append(contentsOf: [0xC3, 0x28, 0x0A])
        fs.files[p]!.data.append(bin)
        XCTAssertFalse(r.fileChanged(p, now: t0 + 2))
        XCTAssertEqual(r.status(now: t0 + 2).phase, .working)
    }

    // A5
    func testPartialLineOnlyOnce() {
        let fs = MemFS(); let r = codex(fs); let p = dayDir(t0) + "/rollout-a.jsonl"
        r.keepsEventLog = true
        let line = ev("task_started")
        push(r, fs, p, String(line.dropLast(10)), at: t0)
        XCTAssertEqual(r.status(now: t0).phase, .idle)
        push(r, fs, p, String(line.suffix(10)), at: t0 + 1)
        XCTAssertEqual(r.status(now: t0 + 1).phase, .working)
        push(r, fs, p, ev("token_count"), at: t0 + 2)
        XCTAssertEqual(r.eventLog, ["task_started"])
    }

    // A6
    func testRotation() {
        let fs = MemFS(); let r = codex(fs); let p = dayDir(t0) + "/rollout-a.jsonl"
        push(r, fs, p, ev("task_started") + ev("task_complete"), at: t0)
        XCTAssertEqual(r.status(now: t0).phase, .done)
        // 变小：偏移归零重读
        fs.write(p, ev("task_started"), mtime: t0 + 1)
        r.fileChanged(p, now: t0 + 1)
        XCTAssertEqual(r.status(now: t0 + 1).phase, .working)
        // 删除：会话移除
        fs.files[p] = nil
        r.fileChanged(p, now: t0 + 2)
        XCTAssertEqual(r.sessionCount, 0)
        XCTAssertEqual(r.status(now: t0 + 2).phase, .idle)
        // 新文件超过 64KB：只读末尾 64KB
        let filler = String(repeating: ev("token_count"), count: 2000)
        XCTAssertGreaterThan(filler.utf8.count, 64 * 1024)
        fs.maxRead = 0
        fs.write(p, filler + ev("task_started"), mtime: t0 + 3)
        r.fileChanged(p, now: t0 + 3)
        XCTAssertLessThanOrEqual(fs.maxRead, 64 * 1024)
        XCTAssertEqual(r.status(now: t0 + 3).phase, .working)
        // 一次最多读 1MB
        let mb = String(repeating: ev("token_count"), count: 25_000)
        fs.maxRead = 0
        fs.append(p, mb, mtime: t0 + 4)
        var rounds = 1
        while r.fileChanged(p, now: t0 + 4) { rounds += 1 }
        XCTAssertGreaterThan(rounds, 1)
        XCTAssertLessThanOrEqual(fs.maxRead, 1024 * 1024)
    }

    // A7
    func testTimeouts() {
        let fs = MemFS(); let r = codex(fs); let p = dayDir(t0) + "/rollout-a.jsonl"
        push(r, fs, p, ev("task_started"), at: t0)
        push(r, fs, p, "anything that is not json\n", at: t0 + 599)
        XCTAssertEqual(r.status(now: t0 + 599 + 599).phase, .working)
        XCTAssertEqual(r.nextDeadline(), t0 + 599 + 600)
        XCTAssertEqual(r.status(now: t0 + 599 + 600).phase, .idle)
        for (e, tool) in [("task_complete", AgentTool.codex), ("turn_aborted", .codex)] {
            let f = MemFS(); let c = codex(f)
            push(c, f, p, ev(e), at: t0)
            XCTAssertNotEqual(c.status(now: t0 + 59).phase, .idle, "\(e) \(tool)")
            XCTAssertEqual(c.status(now: t0 + 60).phase, .idle)
        }
        let fa = MemFS(); let a = ag(fa); let q = aroot + "/x/transcript.jsonl"
        push(a, fa, q, st("ERROR"), at: t0)
        XCTAssertEqual(a.status(now: t0 + 59).phase, .failed)
        XCTAssertEqual(a.status(now: t0 + 60).phase, .idle)
    }

    // A8
    func testMerge() {
        var w1 = AgentSession(); w1.apply(.taskStarted, at: t0 + 100)
        var w2 = AgentSession(); w2.apply(.taskStarted, at: t0)
        var d = AgentSession(); d.apply(.taskComplete, at: t0)
        var f = AgentSession(); f.apply(.turnAborted, at: t0)
        var a = AgentSession(); a.apply(.askStart(callID: "c"), at: t0 + 5)
        XCTAssertEqual(AgentSessionReader.merge([d, w1, f, w2]), AgentToolStatus(phase: .working, since: t0))
        XCTAssertEqual(AgentSessionReader.merge([d, f]).phase, .failed)
        XCTAssertEqual(AgentSessionReader.merge([d, AgentSession()]).phase, .done)
        XCTAssertEqual(AgentSessionReader.merge([w1, a, f]).phase, .asking)
        XCTAssertEqual(AgentSessionReader.merge([]), .idle)
        XCTAssertEqual(AgentSnapshot(codex: AgentToolStatus(phase: .done), antigravity: AgentToolStatus(phase: .working)).dot, .working)
        XCTAssertEqual(AgentSnapshot(codex: AgentToolStatus(phase: .asking), antigravity: AgentToolStatus(phase: .working)).dot, .asking)
        XCTAssertEqual(AgentSnapshot(codex: AgentToolStatus(phase: .failed), antigravity: AgentToolStatus(phase: .done)).dot, .failed)
        XCTAssertEqual(AgentSnapshot(codex: nil, antigravity: nil).dot, .idle)
        // 文案
        XCTAssertEqual(AgentStatusText.text(AgentToolStatus(phase: .working, since: t0), tool: .codex, now: t0 + 59), "工作中")
        XCTAssertEqual(AgentStatusText.text(AgentToolStatus(phase: .working, since: t0), tool: .codex, now: t0 + 12 * 60), "工作中 · 12 分钟")
        XCTAssertEqual(AgentStatusText.text(AgentToolStatus(phase: .working, since: t0), tool: .antigravity, now: t0 + 3600), "工作中 · 1 小时以上")
        XCTAssertEqual(AgentStatusText.text(.idle, tool: .codex, now: t0), "空闲")
        XCTAssertEqual(AgentStatusText.text(AgentToolStatus(phase: .done), tool: .codex, now: t0), "刚完成")
        // 颜色
        XCTAssertNil(AgentDotStyle.rgb(.idle, dark: true))
        XCTAssertEqual(AgentDotStyle.rgb(.working, dark: false)?.b, 0xFF)
        XCTAssertEqual(AgentDotStyle.rgb(.asking, dark: false)?.g, 0x95)
        XCTAssertTrue(AgentDotStyle.blinks(.working))
        XCTAssertFalse(AgentDotStyle.blinks(.asking))
        XCTAssertEqual(AgentDotStyle.extraWidth, 10)
    }

    // A9
    func testStartupNoHistoryScan() {
        let fs = MemFS()
        let now = t0
        let today = dayDir(now), yesterday = dayDir(now - 86400), old = dayDir(now - 3 * 86400)
        let filler = String(repeating: ev("token_count"), count: 2000)
        fs.write(today + "/rollout-work.jsonl", filler + ev("task_started") + ev("token_count"), mtime: now - 60)
        fs.write(today + "/rollout-done.jsonl", ev("task_started") + ev("task_complete"), mtime: now - 30)
        fs.write(today + "/rollout-stale.jsonl", ev("task_started"), mtime: now - 40 * 60)
        fs.write(today + "/rollout-ask.jsonl", ev("task_started") + "{\"timestamp\":\"\(ISO8601DateFormatter().string(from: now - 20 * 60))\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"request_user_input\",\"call_id\":\"q\"}}\n", mtime: now - 20 * 60)
        fs.write(yesterday + "/rollout-y.jsonl", ev("turn_aborted"), mtime: now - 120)
        fs.write(old + "/rollout-old.jsonl", ev("task_started"), mtime: now)
        fs.write(today + "/notes.txt", "x", mtime: now)
        let r = codex(fs)
        r.start(now: now)
        XCTAssertEqual(Set(fs.listed), [today, yesterday])
        XCTAssertFalse(fs.opens.contains(today + "/rollout-stale.jsonl"))
        XCTAssertFalse(fs.opens.contains(old + "/rollout-old.jsonl"))
        XCTAssertFalse(fs.opens.contains(today + "/notes.txt"))
        XCTAssertLessThanOrEqual(fs.maxRead, 64 * 1024)
        let phases = r.sessions.values.map(\.phase).sorted()
        XCTAssertEqual(phases, [.idle, .idle, .working, .asking])
        XCTAssertEqual(r.status(now: now).phase, .asking)
        // 增量读从末尾接着来
        fs.opens = []
        push(r, fs, today + "/rollout-done.jsonl", ev("task_started"), at: now + 1)
        XCTAssertEqual(fs.maxRead, 64 * 1024) // 之前的最大值不变
        XCTAssertEqual(r.sessions.values.filter { $0.phase == .working }.count, 2)

        // Antigravity：只列 brain/ 一级，10 分钟前的文件不打开
        let fa = MemFS()
        fa.write(aroot + "/s1/transcript.jsonl", st("RUNNING"), mtime: now - 30)
        fa.write(aroot + "/s2/.system_generated/logs/transcript.jsonl", st("RUNNING"), mtime: now - 30)
        fa.write(aroot + "/s3/transcript.jsonl", st("RUNNING"), mtime: now - 3600)
        fa.write(aroot + "/s4/transcript.jsonl", st("RUNNING") + fin, mtime: now - 30)
        let a = ag(fa)
        a.start(now: now)
        XCTAssertEqual(fa.listed, [aroot])
        XCTAssertFalse(fa.opens.contains(aroot + "/s3/transcript.jsonl"))
        XCTAssertEqual(a.sessions.values.filter { $0.phase == .working }.count, 2)
        XCTAssertEqual(a.status(now: now).phase, .working)
    }

    // A10
    func testNoContentInMemory() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/agent-status")
        let c = try String(contentsOf: dir.appendingPathComponent("codex-basic.jsonl"))
        let g = try String(contentsOf: dir.appendingPathComponent("antigravity-basic.jsonl"))
        let fs = MemFS(); let r = codex(fs); r.keepsEventLog = true
        let p = dayDir(t0) + "/rollout-2026-11-27T08-00-00-FIXTURE_SESSION_ID_123.jsonl"
        push(r, fs, p, c, at: t0)
        XCTAssertEqual(r.eventLog, ["task_started", "ask_start", "ask_output", "task_complete"])
        XCTAssertEqual(r.status(now: t0).phase, .done)
        let fa = MemFS(); let a = ag(fa); a.keepsEventLog = true
        push(a, fa, aroot + "/FIXTURE_SESSION_ID_123/transcript.jsonl", g, at: t0)
        XCTAssertEqual(a.eventLog, ["activity", "final", "final", "activity"])
        for reader in [r, a] {
            let dump = String(describing: reader.sessions) + String(describing: reader.cursors) + reader.eventLog.joined()
                + String(reflecting: reader.status(now: t0))
            for bad in ["FIXTURE_MARKER_BODY", "FIXTURE_SESSION_ID_123", "SECRET"] {
                XCTAssertFalse(dump.contains(bad), bad)
            }
            for child in Mirror(reflecting: reader).children {
                let s = String(describing: child.value)
                XCTAssertFalse(s.contains("FIXTURE_MARKER_BODY"))
                XCTAssertFalse(s.contains("FIXTURE_SESSION_ID_123"), child.label ?? "")
            }
        }
    }

    // 只解析状态行：没有关键字的行不做 JSON 解析也不出事件
    func testParserPrefilter() {
        XCTAssertNil(AgentLineParser.codex(Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}".utf8), pending: []))
        XCTAssertEqual(AgentLineParser.codex(Data(ask("z").dropLast().utf8), pending: [])?.event, .askStart(callID: "z"))
        XCTAssertNil(AgentLineParser.codex(Data(out("z").dropLast().utf8), pending: []))
        XCTAssertEqual(AgentLineParser.codex(Data(out("z").dropLast().utf8), pending: ["z"])?.event, .askOutput(callID: "z"))
        XCTAssertEqual(AgentLineParser.antigravity(Data(st("RUNNING").utf8)), .activity)
        XCTAssertEqual(AgentLineParser.antigravity(Data(fin.utf8)), .turnEnd)
        XCTAssertNil(AgentLineParser.antigravity(Data("{\"status\":\"RUNNING\"}".utf8)))
        XCTAssertNil(AgentLineParser.antigravity(Data("{bad".utf8)))
    }

    func testDebugSnapshotParse() {
        let s = AgentSnapshot.parseDebug("codex:working:12,antigravity:error", now: t0)
        XCTAssertEqual(s.codex, AgentToolStatus(phase: .working, since: t0 - 720))
        XCTAssertEqual(s.antigravity?.phase, .failed)
        XCTAssertEqual(s.debugText, "codex:working,antigravity:failed")
    }
}
