import AhenkKit
import AppKit
import Darwin

/// Which browser app holds a connection to the bridge: the process that owns
/// the other end of the loopback socket (read from the kernel's file tables,
/// as `lsof` does; only this user's processes, no permission involved), then
/// the app responsible for it (Chromium opens WebSockets from its network
/// helper; the helper's app is the browser). Falls back to the name the
/// extension reports when the socket cannot be found.
enum BrowserProcessLookup {
    static func identify(clientPort: UInt16, serverPort: UInt16, hello: BridgeHello) -> BridgeBrowserProcess? {
        if let owner = socketOwner(clientPort: clientPort, serverPort: serverPort), let app = app(owning: owner) {
            return app
        }
        for bundle in BrowserIdentity.bundleCandidates(for: hello.browser) {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first(where: { !$0.isTerminated }) {
                return BridgeBrowserProcess(processIdentifier: running.processIdentifier, bundleIdentifier: bundle)
            }
        }
        return nil
    }

    /// The process with a TCP socket from `clientPort` to `serverPort` on
    /// this Mac (Ahenk itself only when asked: the smoke check connects to
    /// its own server).
    static func socketOwner(clientPort: UInt16, serverPort: UInt16, includingSelf: Bool = false) -> pid_t? {
        let own = getpid()
        if includingSelf, hasSocket(own, local: clientPort, remote: serverPort) { return own }
        for pid in allProcesses() where pid > 0 && pid != own {
            if hasSocket(pid, local: clientPort, remote: serverPort) { return pid }
        }
        return nil
    }

    private static func allProcesses() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 32)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        // Newest processes first: a browser's network helper is rarely old.
        return Array(pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride)).sorted(by: >)
    }

    private static func hasSocket(_ pid: pid_t, local: UInt16, remote: UInt16) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let filled = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return false }
        for descriptor in descriptors.prefix(Int(filled) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            let socket = info.psi
            guard socket.soi_kind == Int32(SOCKINFO_TCP), socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else { continue }
            let tcp = socket.soi_proto.pri_tcp.tcpsi_ini
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.insi_lport))
            let remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.insi_fport))
            if localPort == local, remotePort == remote { return true }
        }
        return false
    }

    /// The app behind a process. First the app bundle its executable lies in
    /// (a browser's helpers live inside the browser's own bundle), with the
    /// topmost process running from that bundle as the browser's main
    /// process; this also works for a browser that LaunchServices does not
    /// know (one started from a terminal, whose "responsible" process is the
    /// terminal). Else the process itself, the app responsible for it, or
    /// the nearest ancestor that is an app (a browser first).
    static func app(owning pid: pid_t) -> BridgeBrowserProcess? {
        if let bundle = outermostApp(of: pid), bundle.identifier != Bundle.main.bundleIdentifier {
            var main = pid
            for ancestor in CoreAudioQueries.ancestors(of: pid) where ancestor > 1 {
                guard outermostApp(of: ancestor)?.url == bundle.url else { break }
                main = ancestor
            }
            return BridgeBrowserProcess(processIdentifier: main, bundleIdentifier: bundle.identifier)
        }
        var chain: [pid_t] = [pid]
        if let responsible = CoreAudioQueries.responsiblePID(of: pid), responsible != pid { chain.append(responsible) }
        chain += CoreAudioQueries.ancestors(of: pid).filter { $0 > 1 }
        var regular: BridgeBrowserProcess?
        var other: BridgeBrowserProcess?
        let resolver = SourceResolver.standard
        for candidate in chain {
            guard let app = NSRunningApplication(processIdentifier: candidate), let bundle = app.bundleIdentifier else { continue }
            let found = BridgeBrowserProcess(processIdentifier: candidate, bundleIdentifier: bundle)
            if resolver.isBrowser(bundle) { return found }
            if app.activationPolicy == .regular {
                if regular == nil { regular = found }
            } else if other == nil, !bundle.hasSuffix(".helper"), !bundle.contains(".helper.") {
                other = found
            }
        }
        return regular ?? other
    }

    /// The outermost `.app` a process's executable lies in, and its bundle
    /// identifier ("…/Google Chrome.app" for Chrome's helpers, which are
    /// apps nested inside it).
    static func outermostApp(of pid: pid_t) -> (url: URL, identifier: String)? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let parts = String(cString: buffer).split(separator: "/", omittingEmptySubsequences: true)
        guard let top = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let url = URL(fileURLWithPath: "/" + parts[...top].joined(separator: "/"), isDirectory: true)
        guard let identifier = Bundle(url: url)?.bundleIdentifier else { return nil }
        return (url, identifier)
    }
}
