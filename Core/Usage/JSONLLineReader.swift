import Foundation

/// 从指定字节偏移开始流式按行读取 JSONL。
/// 不整份读入：用一块可复用的缓冲区(1 MB 起，只在单行比它还长时扩大)循环读，内存与文件大小无关。
/// 调用方给出关键词，只有含其中任一关键词的完整行才交给回调解析——日志里绝大多数字节是对话正文和工具输出，
/// 先按字节筛掉，能省下大部分 JSON 解析。关键词只是粗筛，回调里仍要按结构判断。
/// 末尾没有换行的残行不消费，新偏移停在最后一个换行之后，等下次写完整再读。
enum JSONLLineReader {
    nonisolated static let chunkSize = 1 << 20

    /// 读 `url` 中 `offset` 之后的完整行。返回新偏移；文件打不开 / 读失败返回 nil(此时回调可能已收到部分行，
    /// 调用方应丢弃本文件这次的结果)。
    nonisolated static func scan(url: URL, fromOffset offset: UInt64, keywords: [String], _ body: (Data) -> Void) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if offset >= end { return end }
        do { try handle.seek(toOffset: offset) } catch { return nil }
        guard let read = readLines(fd: handle.fileDescriptor, skip: 0, keywords: keywords, body) else { return nil }
        return offset + read.end
    }

    /// 流式解压 `.jsonl.zst` 并按行读取 `offset`(解压后的字节偏移)之后的内容，规则同 `scan(url:)`。
    /// 返回新偏移和解压后总长度(调用方据此发现偏移越界);没有 zstd 命令或解压失败返回 nil。
    nonisolated static func scanZstd(url: URL, fromOffset offset: UInt64, keywords: [String], _ body: (Data) -> Void) -> (newOffset: UInt64, total: UInt64)? {
        guard let binary = zstdBinary else { return nil }
        // 每个文件的 Process / Pipe 在这里就释放，不留到整次扫描结束(扫描线程没有 RunLoop 替我们清理)。
        return autoreleasepool {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["-dcq", url.path]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            // 不用 waitUntilExit:它靠 RunLoop 等退出通知，每个文件要多等几十毫秒，几百个压缩会话就是几十秒。
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do { try process.run() } catch { return nil }
            // 偏移之前的内容上次已经扫过，解压流里直接跳过。
            let read = readLines(fd: out.fileHandleForReading.fileDescriptor, skip: offset, keywords: keywords, body)
            try? out.fileHandleForReading.close()
            exited.wait()
            guard let read, process.terminationStatus == 0 else { return nil }
            return (read.end, read.total)
        }
    }

    /// 从 `fd` 读到结尾。前 `skip` 字节丢弃，之后按 `\n` 切成整行，含关键词的行交给 `body`。
    /// 返回最后一个换行之后在流中的位置(没有新行时为 `skip`)和流的总长度；读出错返回 nil。
    private nonisolated static func readLines(fd: Int32, skip: UInt64, keywords: [String], _ body: (Data) -> Void) -> (end: UInt64, total: UInt64)? {
        let patterns = keywords.map { Array($0.utf8) }
        var capacity = chunkSize
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        // buffer[0..<filled] 是还没切出的残行加新读入的内容，buffer[0] 位于流中的 `end`。
        var filled = 0
        var searched = 0
        var total: UInt64 = 0
        var end = skip
        while true {
            if filled == capacity {
                // 一行比缓冲区还长：扩大(只有超长行会走到这里)。
                let bigger = UnsafeMutableRawPointer.allocate(byteCount: capacity * 2, alignment: 16)
                bigger.copyMemory(from: buffer, byteCount: filled)
                buffer.deallocate()
                buffer = bigger
                capacity *= 2
            }
            let n = read(fd, buffer + filled, capacity - filled)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            let readStart = total
            total += UInt64(n)
            if total <= skip { continue }
            if readStart < skip {
                // 这次读入的前一部分还在 skip 之前(此时 filled 必为 0)。
                let drop = Int(skip - readStart)
                memmove(buffer, buffer + drop, n - drop)
                filled = n - drop
            } else {
                filled += n
            }

            var lineStart = 0
            autoreleasepool {
                var cursor = searched
                while cursor < filled, let hit = memchr(buffer + cursor, 0x0A, filled - cursor) {
                    let lineEnd = buffer.distance(to: hit)
                    let length = lineEnd - lineStart
                    if length > 0, contains(buffer + lineStart, length, patterns) {
                        body(Data(bytes: buffer + lineStart, count: length))
                    }
                    lineStart = lineEnd + 1
                    cursor = lineStart
                }
            }
            if lineStart > 0 {
                end += UInt64(lineStart)
                filled -= lineStart
                if filled > 0 { memmove(buffer, buffer + lineStart, filled) }
            }
            searched = filled
        }
        return (end, total)
    }

    private nonisolated static func contains(_ line: UnsafeRawPointer, _ length: Int, _ patterns: [[UInt8]]) -> Bool {
        if patterns.isEmpty { return true }
        for pattern in patterns where pattern.count <= length {
            let found = pattern.withUnsafeBytes { memmem(line, length, $0.baseAddress, pattern.count) != nil }
            if found { return true }
        }
        return false
    }

    /// 解压 zstd 需要的命令。Codex 会把旧会话压成 `.jsonl.zst`;系统没有 zstd 解码库，借用 Homebrew / MacPorts
    /// 安装的 `zstd` 命令。
    nonisolated static let zstdBinary: URL? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/opt/local/bin/zstd", "\(home)/.local/bin/zstd", "/usr/bin/zstd"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()
}

/// 日志里的 ISO 8601 时间戳(带或不带小数秒)。格式化器创建成本高，全量扫描有几万行，共用一份;
/// ISO8601DateFormatter 是线程安全的，三个扫描器并行使用没问题。
enum JSONLTimestamp {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated static func parse(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }
}

/// 递归列出某目录下后缀为 .jsonl 的文件;`includeZstd` 时也包括 `.jsonl.zst`。
enum JSONLDirectoryEnumerator {
    nonisolated static func files(at root: URL, includeZstd: Bool = false) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in it {
            if url.pathExtension.lowercased() == "jsonl"
                || (includeZstd && url.lastPathComponent.lowercased().hasSuffix(".jsonl.zst")) {
                result.append(url)
            }
        }
        return result
    }
}
