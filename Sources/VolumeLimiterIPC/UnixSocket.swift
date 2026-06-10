import Darwin
import Foundation

public enum UnixSocketError: Error, LocalizedError, Equatable {
    case pathTooLong(String)
    case systemCall(String, Int32)
    case disconnected
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case let .pathTooLong(path):
            "Unix domain socket path is too long: \(path)"
        case let .systemCall(name, errnoValue):
            "\(name) failed: \(String(cString: strerror(errnoValue)))"
        case .disconnected:
            "Socket disconnected before a complete newline-delimited message was received."
        case .invalidUTF8:
            "Socket response was not valid UTF-8."
        }
    }
}

public final class UnixSocketClient {
    private let path: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String = VolumeLimiterIPC.defaultSocketPath()) {
        self.path = path
    }

    public func send(_ request: IPCRequest) throws -> IPCResponse {
        let fd = try connectSocket(path: path)
        defer { close(fd) }

        var data = try encoder.encode(request)
        data.append(0x0A)
        try writeAll(data, to: fd)

        let responseLine = try readLine(from: fd)
        return try decoder.decode(IPCResponse.self, from: Data(responseLine.utf8))
    }
}

public final class UnixSocketServer {
    public typealias Handler = (IPCRequest) -> IPCResponse

    private let path: String
    private let handler: Handler
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let acceptQueue = DispatchQueue(label: "com.volumelimiter.ipc.accept")
    private let connectionQueue = DispatchQueue(label: "com.volumelimiter.ipc.connections", attributes: .concurrent)
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    public init(path: String = VolumeLimiterIPC.defaultSocketPath(), handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !running else {
            return
        }

        try removeStaleSocketIfNeeded(path: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketError.systemCall("socket", errno)
        }

        do {
            try bindSocket(fd: fd, path: path)
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                throw UnixSocketError.systemCall("chmod", errno)
            }
            guard listen(fd, SOMAXCONN) == 0 else {
                throw UnixSocketError.systemCall("listen", errno)
            }
        } catch {
            close(fd)
            unlink(path)
            throw error
        }

        listenFD = fd
        running = true
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        let shouldCleanup = running || fd >= 0
        running = false
        listenFD = -1
        lock.unlock()

        if fd >= 0 {
            close(fd)
        }
        if shouldCleanup {
            unlink(path)
        }
    }

    private func acceptLoop() {
        while isRunning {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }

            connectionQueue.async { [weak self] in
                self?.handleConnection(fd: clientFD)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func handleConnection(fd: Int32) {
        defer { close(fd) }

        let response: IPCResponse
        do {
            let line = try readLine(from: fd)
            let requestData = Data(line.utf8)
            do {
                let request = try decoder.decode(IPCRequest.self, from: requestData)
                response = handler(request)
            } catch {
                response = IPCResponse.failure(
                    id: requestID(from: requestData) ?? "",
                    code: "invalidRequest",
                    message: error.localizedDescription
                )
            }
        } catch {
            response = IPCResponse.failure(id: "", code: "socketReadFailed", message: error.localizedDescription)
        }

        do {
            var data = try encoder.encode(response)
            data.append(0x0A)
            try writeAll(data, to: fd)
        } catch {
            // The peer may have disconnected; the daemon cannot report this anywhere useful yet.
        }
    }
}

private func connectSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw UnixSocketError.systemCall("socket", errno)
    }

    do {
        try withSockAddrUn(path: path) { pointer, length in
            guard connect(fd, pointer, length) == 0 else {
                throw UnixSocketError.systemCall("connect", errno)
            }
        }
        return fd
    } catch {
        close(fd)
        throw error
    }
}

private func bindSocket(fd: Int32, path: String) throws {
    try withSockAddrUn(path: path) { pointer, length in
        guard bind(fd, pointer, length) == 0 else {
            throw UnixSocketError.systemCall("bind", errno)
        }
    }
}

private func withSockAddrUn<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < 104 else {
        throw UnixSocketError.pathTooLong(path)
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
            for byteOffset in 0..<pathBytes.count {
                destination[byteOffset] = CChar(bitPattern: pathBytes[byteOffset])
            }
            destination[pathBytes.count] = 0
        }
    }

    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            try body(sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func removeStaleSocketIfNeeded(path: String) throws {
    guard FileManager.default.fileExists(atPath: path) else {
        return
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw UnixSocketError.systemCall("socket", errno)
    }
    defer { close(fd) }

    do {
        try withSockAddrUn(path: path) { pointer, length in
            if connect(fd, pointer, length) == 0 {
                throw UnixSocketError.systemCall("bind", EADDRINUSE)
            }
        }
    } catch let error as UnixSocketError {
        if case let .systemCall(_, errnoValue) = error, errnoValue == EADDRINUSE {
            throw error
        }
    }

    guard unlink(path) == 0 else {
        throw UnixSocketError.systemCall("unlink", errno)
    }
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return
        }
        var written = 0
        while written < data.count {
            let result = write(fd, baseAddress.advanced(by: written), data.count - written)
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                throw UnixSocketError.systemCall("write", errno)
            }
            written += result
        }
    }
}

private func readLine(from fd: Int32) throws -> String {
    var data = Data()
    var byte = UInt8(0)

    while true {
        let result = read(fd, &byte, 1)
        if result == 0 {
            throw UnixSocketError.disconnected
        }
        if result < 0 {
            if errno == EINTR {
                continue
            }
            throw UnixSocketError.systemCall("read", errno)
        }
        if byte == 0x0A {
            break
        }
        data.append(byte)
    }

    guard let line = String(data: data, encoding: .utf8) else {
        throw UnixSocketError.invalidUTF8
    }
    return line
}

private func requestID(from data: Data) -> String? {
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let id = object["id"] as? String
    else {
        return nil
    }
    return id
}
