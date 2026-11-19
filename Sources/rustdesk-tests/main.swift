import Foundation
import RustDeskCore

@main
struct RustDeskTestsRunner {
    static func main() {
        testParseOpenAndCloseSession()
        testIgnoreOutgoingClientConnections()
        testNormalizeMappedIPv6AndIPv6()
        testLocalServerRestartClearsWhileRendezvousRestartPreserves()
        testMultipleConcurrentSessionsAndExit()
        testHasActiveCMTask()
        testConnectionStateDebounceAndPeerChange()
        testCMProcessOnlyFallback()
        print("PASS: all RustDeskCore tests passed (8/8)")
    }

    static func testParseOpenAndCloseSession() {
        var parser = RustDeskLogParser()
        parser.feed(line: "[2026-01-01 12:00:00.000000 +08:00] DEBUG [src/server/connection.rs:1507] #101 Connection opened from 100.64.0.10:51000.")
        precondition(parser.activeSessions.count == 1)
        precondition(parser.activeSessions.first?.connId == 101)
        precondition(parser.activeSessions.first?.peerIP == "100.64.0.10")
        precondition(parser.recentPeerIPs == ["100.64.0.10"])

        parser.feed(line: "[2026-01-01 12:00:10.000000 +08:00] INFO [src/server/connection.rs:5319] #101 Connection closed: Peer close")
        precondition(parser.activeSessions.isEmpty)
        precondition(parser.recentPeerIPs == ["100.64.0.10"])
    }

    static func testIgnoreOutgoingClientConnections() {
        var parser = RustDeskLogParser()
        parser.feed(line: "[2026-01-01 12:00:00.000000 +08:00] DEBUG [src/client/io_loop.rs:120] #50 Connection opened from 198.51.100.11:21116.")
        parser.feed(line: "[2026-01-01 12:00:00.100000 +08:00] DEBUG [src/ui_session_interface.rs:88] #51 Connection opened from 198.51.100.10:21116.")
        precondition(parser.activeSessions.isEmpty)
        precondition(parser.recentPeerIPs.isEmpty)
    }

    static func testNormalizeMappedIPv6AndIPv6() {
        precondition(RustDeskLogParser.normalizeIP("[::ffff:100.64.0.10]:51000.") == "100.64.0.10")
        precondition(RustDeskLogParser.normalizeIP("192.168.1.42:54321.") == "192.168.1.42")
        precondition(RustDeskLogParser.normalizeIP("[2001:db8::1]:54321.") == "2001:db8::1")
    }

    static func testLocalServerRestartClearsWhileRendezvousRestartPreserves() {
        var parser = RustDeskLogParser()
        parser.feed(line: "[2026-01-01 12:00:00.000000 +08:00] DEBUG [src/server/connection.rs:1507] #400 Connection opened from 10.0.0.5:12345.")
        precondition(parser.activeSessions.count == 1)

        // rendezvous_mediator server restart 不影响局域网/直连会话
        parser.feed(line: "[2026-01-01 12:00:30.000000 +08:00] INFO [src/rendezvous_mediator.rs:309] server restart")
        precondition(parser.activeSessions.count == 1)

        // 本地 server 重启才会清空旧活跃会话
        parser.feed(line: "[2026-01-01 12:01:00.000000 +08:00] INFO [src/core_main.rs:386] start --server with user demo")
        precondition(parser.activeSessions.isEmpty)

        parser.feed(line: "[2026-01-01 12:01:01.000000 +08:00] DEBUG [src/server/connection.rs:1507] #401 Connection opened from 10.0.0.6:12345.")
        precondition(parser.activeSessions.count == 1)
        parser.feed(line: "[2026-01-01 12:02:00.000000 +08:00] INFO [src/server.rs:780] try start server")
        precondition(parser.activeSessions.isEmpty)

        parser.feed(line: "[2026-01-01 12:02:01.000000 +08:00] DEBUG [src/server/connection.rs:1507] #402 Connection opened from 10.0.0.7:12345.")
        precondition(parser.activeSessions.count == 1)
        parser.feed(line: "[2026-01-01 12:02:02.000000 +08:00] INFO [src/ipc.rs:753] Started ipc server at path: /tmp/RustDesk-1000/ipc")
        precondition(parser.activeSessions.isEmpty)
    }

    static func testMultipleConcurrentSessionsAndExit() {
        var parser = RustDeskLogParser()
        parser.feed(line: "[2026-01-01 12:00:01 +08:00] DEBUG [src/server/connection.rs:1507] #10 Connection opened from 100.64.0.10:50001.")
        parser.feed(line: "[2026-01-01 12:00:02 +08:00] DEBUG [src/server/connection.rs:1507] #11 Connection opened from 100.64.0.20:50002.")
        precondition(parser.activeSessions.map(\.connId) == [10, 11])
        precondition(parser.recentPeerIPs == ["100.64.0.20", "100.64.0.10"])

        parser.feed(line: "[2026-01-01 12:00:10 +08:00] INFO [src/server/connection.rs:1250] #10 connection loop exited")
        precondition(parser.activeSessions.map(\.connId) == [11])

        parser.feed(line: "[2026-01-01 12:00:20 +08:00] INFO [libs/scrap/src/common/codec.rs:172] update:Remove(11)")
        precondition(parser.activeSessions.isEmpty)
    }

    static func testHasActiveCMTask() {
        let activeLog = """
        [2026-01-01 12:00:01.000000 +08:00] INFO [src/ipc.rs:753] Started ipc_cm server at path: /tmp/RustDesk-1000/ipc_cm
        [2026-01-01 12:00:01.100000 +08:00] DEBUG [src/ui_cm_interface.rs:862] Got new connection
        [2026-01-01 12:00:01.100100 +08:00] DEBUG [src/ui_cm_interface.rs:816] ipc task begin
        [2026-01-01 12:00:01.100200 +08:00] DEBUG [src/ui_cm_interface.rs:558] conn_id: 101
        """
        precondition(RustDeskLogParser.hasActiveCMTask(in: activeLog))

        let closedLog = activeLog + "\n[2026-01-01 12:00:10.000000 +08:00] DEBUG [src/ui_cm_interface.rs:841] ipc task end\n"
        precondition(!RustDeskLogParser.hasActiveCMTask(in: closedLog))

        let restartedLog = activeLog + "\n[2026-01-01 12:01:00 +08:00] INFO [src/ipc.rs:753] Started ipc_cm server at path: /tmp/RustDesk-1000/ipc_cm\n"
        precondition(!RustDeskLogParser.hasActiveCMTask(in: restartedLog))
    }

    static func testConnectionStateDebounceAndPeerChange() {
        var state = RustDeskConnectionState(debounce: 1.5)
        let t0 = Date(timeIntervalSince1970: 1000)

        let s1 = RustDeskSession(connId: 1, peerIP: "100.64.0.10", openedAt: t0)
        precondition(state.update(activeSessions: [s1], cmProcessActive: true, now: t0) == .connected)
        precondition(state.connected)
        precondition(state.currentPeerIP == "100.64.0.10")

        // 短暂断开（1.0s < 1.5s）不触发断开
        precondition(state.update(activeSessions: [], cmProcessActive: false, now: t0.addingTimeInterval(1.0)) == nil)
        precondition(state.connected)

        // 换成另一台设备连入
        let s2 = RustDeskSession(connId: 2, peerIP: "198.51.100.11", openedAt: t0.addingTimeInterval(1.2))
        precondition(state.update(activeSessions: [s2], cmProcessActive: true, now: t0.addingTimeInterval(1.2)) == .peerChanged)
        precondition(state.currentPeerIP == "198.51.100.11")

        // 即使距离上次活跃回调已超过防抖时长，首次检测到断开时仍须重新起算防抖，不可立即断开
        precondition(state.update(activeSessions: [], cmProcessActive: false, now: t0.addingTimeInterval(5.0)) == nil)
        precondition(state.connected)
        precondition(state.update(activeSessions: [], cmProcessActive: false, now: t0.addingTimeInterval(6.0)) == nil)
        precondition(state.connected)

        // 自首次观察到断开起持续 >= 防抖时间（1.6s >= 1.5s）后触发断开
        precondition(state.update(activeSessions: [], cmProcessActive: false, now: t0.addingTimeInterval(6.6)) == .disconnected)
        precondition(!state.connected)
        precondition(state.currentPeerIP == nil)
    }

    static func testCMProcessOnlyFallback() {
        var state = RustDeskConnectionState(debounce: 1.5)
        let t0 = Date(timeIntervalSince1970: 2000)

        // 即使日志没扫到，--cm 进程存在也能触发 connected
        precondition(state.update(activeSessions: [], cmProcessActive: true, now: t0) == .connected)
        precondition(state.connected)
        precondition(state.currentPeerIP == nil)

        precondition(state.update(activeSessions: [], cmProcessActive: false, now: t0.addingTimeInterval(2.0)) == nil)
        precondition(state.connected)
        precondition(state.update(activeSessions: [], cmProcessActive: false, now: t0.addingTimeInterval(3.6)) == .disconnected)
        precondition(!state.connected)
    }
}
