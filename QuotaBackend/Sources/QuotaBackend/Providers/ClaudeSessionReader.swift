import Foundation

/// JSONL 只保留统计字段；正文、图片和工具参数在流中跳过，不受原始行长度限制。
/// 游标仅缓存在内存。追加读增量；替换、裁剪或边界变化时回到文件开头。
enum ClaudeSessionReader {
    struct Cursor {
        let identity: String
        let size: UInt64
        let modified: Date
        let offset: UInt64
        let head: Data
        let tail: Data
    }
    struct Result {
        let cursor: Cursor
        let errorCode: String?
    }

    static func scan(path: String, cursor: Cursor?, onRow: (Data) -> Void) throws -> Result {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attrs[.modificationDate] as? Date ?? .distantPast
        let identity = "\(attrs[.systemNumber] ?? 0):\(attrs[.systemFileNumber] ?? 0)"
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        func sample(_ offset: UInt64, _ count: Int) throws -> Data {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
        let head = try sample(0, Int(min(size, 128)))
        if let cursor, cursor.identity == identity, cursor.size == size, cursor.modified == modified {
            return Result(cursor: cursor, errorCode: nil)
        }
        var start: UInt64 = 0
        if let cursor, cursor.identity == identity, size > cursor.size,
           head.prefix(cursor.head.count) == cursor.head,
           try sample(cursor.offset - UInt64(cursor.tail.count), cursor.tail.count) == cursor.tail {
            start = cursor.offset
        }
        try handle.seek(toOffset: start)
        let bytes = Bytes(handle: handle, offset: start, limit: size)
        var committed = start
        var errorCode: String?
        while try bytes.peek() != nil {
            try autoreleasepool {
                try bytes.whitespace()
                if try bytes.peek() == 10 { _ = try bytes.take(); committed = bytes.position; return }
                if try bytes.peek() == nil { return }
                let lineStart = bytes.position
                let projection = Projection(bytes: bytes)
                do {
                    let row = try projection.value(.root)
                    try bytes.whitespace()
                    guard try bytes.peek() == nil || bytes.peek() == 10 else { throw ParseError.invalid }
                    if try bytes.peek() == 10 {
                        _ = try bytes.take()
                        committed = bytes.position
                    } else {
                        // 完整但尚未换行的尾行可统计；下次追加仍从该行重读。
                        committed = lineStart
                    }
                    if projection.exceededLimit { errorCode = "session_projection_limit" }
                    else { onRow(row) }
                } catch is ParseError {
                    var terminated = false
                    while let byte = try bytes.take() {
                        if byte == 10 { terminated = true; break }
                    }
                    committed = terminated ? bytes.position : lineStart
                    // 未完成尾行等待下一次写入；已结束的异常行显式标记部分数据。
                    if terminated { errorCode = "session_invalid_row" }
                }
            }
        }
        let tailCount = Int(min(committed, 256))
        let tail = try sample(committed - UInt64(tailCount), tailCount)
        return Result(cursor: Cursor(identity: identity, size: size, modified: modified,
            offset: committed, head: head, tail: tail), errorCode: errorCode)
    }

    private enum ParseError: Error { case invalid }

    private final class Bytes {
        let handle: FileHandle
        let limit: UInt64
        var position: UInt64
        var buffer = Data()
        var index = 0
        init(handle: FileHandle, offset: UInt64, limit: UInt64) {
            self.handle = handle; self.position = offset; self.limit = limit
        }
        func peek() throws -> UInt8? {
            if index == buffer.count {
                guard position < limit else { return nil }
                buffer = try autoreleasepool {
                    try handle.read(upToCount: Int(min(256 * 1024, limit - position))) ?? Data()
                }
                index = 0
                guard !buffer.isEmpty else { throw CocoaError(.fileReadUnknown) }
            }
            return buffer[index]
        }
        func take() throws -> UInt8? {
            guard let byte = try peek() else { return nil }
            index += 1; position += 1
            return byte
        }
        func whitespace() throws {
            while let byte = try peek(), byte == 32 || byte == 9 || byte == 13 { _ = try take() }
        }
        // 用 memchr 跳过长字符串，转义引号不会误判为结束。最多保留指定字节。
        func string(cap: Int) throws -> Data? {
            guard try take() == 34 else { throw ParseError.invalid }
            var result = Data([34])
            var tooLong = false
            var previousSlashes = 0
            while try peek() != nil {
                let begin = index
                let found: Int? = buffer.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress, let pointer = memchr(base.advanced(by: begin), 34, raw.count - begin) else { return nil }
                    return base.distance(to: pointer)
                }
                let end = found ?? buffer.count
                let invalid = buffer.withUnsafeBytes { raw in
                    memchr(raw.baseAddress!.advanced(by: begin), 10, end - begin) != nil
                }
                if invalid { throw ParseError.invalid }
                var slashes = 0, probe = end
                while probe > begin, buffer[probe - 1] == 92 { slashes += 1; probe -= 1 }
                if probe == begin { slashes += previousSlashes }
                let consumed = end - begin + (found == nil ? 0 : 1)
                if !tooLong, result.count + consumed <= cap { result.append(buffer[begin..<(begin + consumed)]) }
                else { tooLong = true }
                index += consumed; position += UInt64(consumed)
                if found != nil, slashes % 2 == 0 { return tooLong ? nil : result }
                previousSlashes = found == nil ? slashes : 0
            }
            throw ParseError.invalid
        }
        func skipValue() throws {
            try whitespace()
            guard let first = try peek() else { throw ParseError.invalid }
            if first == 34 { _ = try string(cap: 0); return }
            if first == 123 || first == 91 {
                var depth = 0
                repeat {
                    guard let byte = try peek(), byte != 10 else { throw ParseError.invalid }
                    if byte == 34 { _ = try string(cap: 0) }
                    else {
                        _ = try take()
                        if byte == 123 || byte == 91 { depth += 1 }
                        if byte == 125 || byte == 93 { depth -= 1 }
                    }
                } while depth > 0
            } else {
                var count = 0
                while let byte = try peek(), ![44, 125, 93, 32, 9, 13, 10].contains(byte) {
                    _ = try take(); count += 1
                }
                if count == 0 { throw ParseError.invalid }
            }
        }
    }

    private enum Context {
        case root, message, usage, blocks, block, input, scalar
        func field(_ key: String) -> Context? {
            switch (self, key) {
            case (.root, "message"): return .message
            case (.root, "type"), (.root, "timestamp"), (.root, "sessionId"), (.root, "uuid"), (.root, "isSidechain"): return .scalar
            case (.message, "content"): return .blocks
            case (.message, "usage"): return .usage
            case (.message, "id"), (.message, "model"): return .scalar
            case (.usage, "input_tokens"), (.usage, "output_tokens"), (.usage, "cache_read_input_tokens"), (.usage, "cache_creation_input_tokens"): return .scalar
            case (.block, "input"): return .input
            case (.block, "type"), (.block, "id"), (.block, "name"), (.block, "tool_use_id"), (.block, "is_error"): return .scalar
            case (.input, "skill"): return .scalar
            default: return nil
            }
        }
    }

    private final class Projection {
        let bytes: Bytes
        var exceededLimit = false
        private let cap = 1024 * 1024
        init(bytes: Bytes) { self.bytes = bytes }
        func append(_ part: Data, to result: inout Data) {
            if result.count + part.count <= cap { result.append(part) }
            else { exceededLimit = true }
        }
        func value(_ context: Context) throws -> Data {
            try bytes.whitespace()
            guard let first = try bytes.peek() else { throw ParseError.invalid }
            if context == .scalar {
                if first == 34 {
                    guard let text = try bytes.string(cap: 16 * 1024) else { exceededLimit = true; return Data("null".utf8) }
                    return text
                }
                if first == 123 || first == 91 { try bytes.skipValue(); return Data("null".utf8) }
                var result = Data()
                while let byte = try bytes.peek(), ![44, 125, 93, 32, 9, 13, 10].contains(byte) {
                    _ = try bytes.take()
                    if result.count < 128 { result.append(byte) } else { exceededLimit = true }
                }
                guard !result.isEmpty else { throw ParseError.invalid }
                return result
            }
            if context == .blocks, first == 91 {
                _ = try bytes.take()
                var result = Data([91]), firstItem = true
                try bytes.whitespace()
                while try bytes.peek() != 93 {
                    if !firstItem { guard try bytes.take() == 44 else { throw ParseError.invalid }; try bytes.whitespace() }
                    let part = try value(.block)
                    if !firstItem { append(Data([44]), to: &result) }
                    append(part, to: &result); firstItem = false
                    try bytes.whitespace()
                }
                _ = try bytes.take(); append(Data([93]), to: &result)
                return result
            }
            guard first == 123, context != .blocks else { try bytes.skipValue(); return Data("null".utf8) }
            _ = try bytes.take()
            var result = Data([123]), firstField = true, firstInputField = true
            try bytes.whitespace()
            while try bytes.peek() != 125 {
                if !firstInputField { guard try bytes.take() == 44 else { throw ParseError.invalid }; try bytes.whitespace() }
                firstInputField = false
                let rawKey = try bytes.string(cap: 1024)
                let key = rawKey.flatMap { raw -> String? in
                    if !raw.contains(92) { return String(data: raw.dropFirst().dropLast(), encoding: .utf8) }
                    return try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? String
                }
                try bytes.whitespace()
                guard try bytes.take() == 58 else { throw ParseError.invalid }
                if let rawKey, let key, let child = context.field(key) {
                    let part = try value(child)
                    if !firstField { append(Data([44]), to: &result) }
                    append(rawKey, to: &result); append(Data([58]), to: &result); append(part, to: &result)
                    firstField = false
                } else { try bytes.skipValue() }
                try bytes.whitespace()
            }
            _ = try bytes.take(); append(Data([125]), to: &result)
            return result
        }
    }
}
