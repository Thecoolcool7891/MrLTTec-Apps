import Foundation
import Darwin

struct AppError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

private let privateIpRx = try! NSRegularExpression(pattern: #"^(10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+)$"#)

func isPrivateIp(_ s: String) -> Bool {
    privateIpRx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

@discardableResult
func assertLocalIp(_ ip: String?) throws -> String {
    guard let ip, isPrivateIp(ip) else { throw AppError("Only local network IP addresses are allowed.") }
    return ip
}

/// Plain BSD-socket helpers. One thread drives hundreds of sockets with poll(), which is how a
/// whole /24 gets scanned in a couple of seconds without any special iOS permission beyond Local Network.
enum LowNet {
    static func raiseFileLimit() {
        var r = rlimit()
        if getrlimit(RLIMIT_NOFILE, &r) == 0 {
            r.rlim_cur = min(r.rlim_max, 4096)
            setrlimit(RLIMIT_NOFILE, &r)
        }
    }

    // MARK: Addresses

    /// This phone's private IPv4 addresses on Wi-Fi / Ethernet / hotspot (not cellular).
    static func localAddrs() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let i = cur.pointee
            p = i.ifa_next
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            guard (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let ip = ipString(sa)
            if isPrivateIp(ip), !out.contains(ip) { out.append(ip) }
        }
        return out
    }

    /// Every address 1...254 on each local /24.
    static func subnetIps() -> [String] {
        var nets: [String] = []
        for a in localAddrs() {
            let n = a.split(separator: ".").prefix(3).joined(separator: ".")
            if !nets.contains(n) { nets.append(n) }
        }
        return nets.flatMap { n in (1...254).map { "\(n).\($0)" } }
    }

    static func ipString(_ sa: UnsafePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return String(cString: host)
    }

    static func makeAddr(_ ip: String, _ port: UInt16) -> sockaddr_in? {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return nil }
        return a
    }

    static func sendTo(_ fd: Int32, _ data: Data, _ ip: String, _ port: UInt16) -> Bool {
        guard var a = makeAddr(ip, port) else { return false }
        let n = data.withUnsafeBytes { b in
            withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, b.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return n == data.count
    }

    static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: TCP sweep

    struct SweepResult {
        var open = Set<String>()      // "ip:port" that accepted
        var alive = Set<String>()     // ips that answered at all (accepted or refused)
    }

    /// Tries to connect to every (ip, port) at once and reports which ones answered within timeoutMs.
    static func tcpSweep(_ targets: [(String, UInt16)], timeoutMs: Int) -> SweepResult {
        var res = SweepResult()
        let chunk = 1500
        var idx = 0
        while idx < targets.count {
            let part = Array(targets[idx..<min(idx + chunk, targets.count)])
            idx += chunk
            var pfds: [pollfd] = []
            var owners: [(String, UInt16)] = []
            for (ip, port) in part {
                guard var a = makeAddr(ip, port) else { continue }
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                if fd < 0 { continue }
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
                let rc = withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if rc == 0 {
                    res.open.insert("\(ip):\(port)"); res.alive.insert(ip); close(fd)
                } else if errno == EINPROGRESS {
                    pfds.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)); owners.append((ip, port))
                } else {
                    if errno == ECONNREFUSED { res.alive.insert(ip) }
                    close(fd)
                }
            }
            let fds = pfds.map { $0.fd }
            let deadline = nowMs() + Double(timeoutMs)
            var pending = pfds.count
            while pending > 0 {
                let left = Int32(max(0, deadline - nowMs()))
                if left <= 0 { break }
                let n = poll(&pfds, nfds_t(pfds.count), left)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
                for i in pfds.indices where pfds[i].fd >= 0 && pfds[i].revents != 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(pfds[i].fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    let (ip, port) = owners[i]
                    if err == 0 { res.open.insert("\(ip):\(port)"); res.alive.insert(ip) }
                    else if err == ECONNREFUSED { res.alive.insert(ip) }
                    pfds[i].fd = -1
                    pending -= 1
                }
            }
            for fd in fds { close(fd) }
        }
        return res
    }

    static func tcpOpen(_ ip: String, _ port: UInt16, timeoutMs: Int = 600) -> Bool {
        tcpSweep([(ip, port)], timeoutMs: timeoutMs).open.contains("\(ip):\(port)")
    }

    // MARK: UDP

    /// Sends payloads to every ip on one UDP socket and collects every reply until waitMs runs out.
    static func udpSweep(_ ips: [String], port: UInt16, payloads: [Data], waitMs: Int, repeats: Int = 1,
                         broadcast: [String] = []) -> [(String, Data)] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { return [] }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var out: [(String, Data)] = []
        let deadline = nowMs() + Double(waitMs)
        for r in 0..<repeats {
            for ip in ips + broadcast {
                for p in payloads { _ = sendTo(fd, p, ip, port) }
            }
            // Spread the repeats across the wait so replies are read in between.
            let until = r == repeats - 1 ? deadline : min(deadline, nowMs() + Double(waitMs) / Double(repeats))
            out += drain(fd, until: until)
        }
        return out
    }

    private static func drain(_ fd: Int32, until: Double) -> [(String, Data)] {
        var out: [(String, Data)] = []
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let left = Int32(max(0, until - nowMs()))
            if left <= 0 { break }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&p, 1, left)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
            var from = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let got = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            if got <= 0 { continue }
            let ip = withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ipString($0) } }
            out.append((ip, Data(buf[0..<got])))
        }
        return out
    }

    /// One request, one reply from that same address (tries twice, like Send-WizUdp).
    static func udpAsk(_ ip: String, port: UInt16, _ payload: Data, waitMs: Int = 1000) -> Data? {
        for _ in 0..<2 {
            let r = udpSweep([ip], port: port, payloads: [payload], waitMs: waitMs)
            if let hit = r.first(where: { $0.0 == ip }) { return hit.1 }
        }
        return nil
    }

    /// Fire-and-forget: tries broadcast addresses too. iOS may refuse broadcast without Apple's multicast
    /// permission; unicast still goes out. Returns how many sends worked.
    @discardableResult
    static func udpSend(_ data: Data, to dests: [String], ports: [UInt16], times: Int = 1, gapMs: UInt32 = 0) -> Int {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { return 0 }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        var ok = 0
        for _ in 0..<times {
            for d in dests { for p in ports { if sendTo(fd, data, d, p) { ok += 1 } } }
            if gapMs > 0 { usleep(gapMs * 1000) }
        }
        return ok
    }

    // MARK: ICMP (ping) — iOS allows unprivileged ICMP echo on a datagram socket.

    private static func checksum(_ b: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < b.count { sum += UInt32(b[i]) << 8 | UInt32(b[i + 1]); i += 2 }
        if i < b.count { sum += UInt32(b[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    private static func echoPacket(id: UInt16, seq: UInt16) -> Data {
        var p: [UInt8] = [8, 0, 0, 0, UInt8(id >> 8), UInt8(id & 0xFF), UInt8(seq >> 8), UInt8(seq & 0xFF)]
        p += Array("MrLTTecPing-0123456789abcdef".utf8)
        let c = checksum(p)
        p[2] = UInt8(c >> 8); p[3] = UInt8(c & 0xFF)
        return Data(p)
    }

    /// Returns ip -> round-trip ms for every address that answered an echo.
    static func icmpSweep(_ ips: [String], waitMs: Int) -> [String: Double] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        if fd < 0 { return [:] }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var sent: [String: Double] = [:]
        for (i, ip) in ips.enumerated() {
            if sendTo(fd, echoPacket(id: 0x4D4C, seq: UInt16(i & 0xFFFF)), ip, 0) { sent[ip] = nowMs() }
        }
        var got: [String: Double] = [:]
        for (ip, d) in drain(fd, until: nowMs() + Double(waitMs)) {
            let b = [UInt8](d)
            var off = 0
            if let f = b.first, f >> 4 == 4 { off = Int(f & 0x0F) * 4 }   // Darwin hands back the IP header too
            guard b.count > off, b[off] == 0, let t = sent[ip], got[ip] == nil else { continue }
            got[ip] = nowMs() - t
        }
        return got
    }

    // MARK: Blocking TCP stream (older Samsung TVs)

    final class Stream {
        let fd: Int32
        init(_ ip: String, _ port: UInt16, connectMs: Int) throws {
            guard var a = makeAddr(ip, port) else { throw AppError("Bad address.") }
            let s = socket(AF_INET, SOCK_STREAM, 0)
            if s < 0 { throw AppError("Could not open a socket.") }
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(s, F_GETFL, 0)
            _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
            let rc = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if rc != 0 {
                guard errno == EINPROGRESS else { close(s); throw AppError("refused") }
                var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, Int32(connectMs)) <= 0 { close(s); throw AppError("timeout") }
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                if err != 0 { close(s); throw AppError("refused") }
            }
            _ = fcntl(s, F_SETFL, flags & ~O_NONBLOCK)
            fd = s
        }
        deinit { close(fd) }

        func setTimeout(_ ms: Int) {
            var tv = timeval(tv_sec: ms / 1000, tv_usec: Int32((ms % 1000) * 1000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }

        func write(_ bytes: [UInt8]) throws {
            var off = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
                if n <= 0 { throw AppError("The TV closed the connection.") }
                off += n
            }
        }

        func read(_ count: Int) throws -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = buf[got...].withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if n <= 0 { throw AppError("The TV closed the connection.") }
                got += n
            }
            return buf
        }
    }

    // MARK: Reverse DNS

    static func hostName(_ ip: String) -> String {
        guard var a = makeAddr(ip, 0) else { return "" }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        return rc == 0 ? String(cString: host) : ""
    }
}

/// Runs blocking socket work off the Swift concurrency pool.
func blocking<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async {
            do { c.resume(returning: try work()) } catch { c.resume(throwing: error) }
        }
    }
}
