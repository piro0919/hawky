import Foundation

/// LevelDB のファイルを読むだけの最小の部品。Claude デスクトップアプリは Chromium の Local Storage に
/// 未読のセッションを置いていて、その中身が LevelDB になっている。書き込みも圧縮の掛け直しもしない。
/// アプリが開いている最中のファイルを読むので、途中で切れた記録は黙って読み飛ばす
enum LevelDB {
    struct Entry: Equatable {
        let sequence: UInt64
        /// 1 が書き込み、0 が削除
        let type: UInt8
        let value: [UInt8]
    }

    /// その鍵の一番新しい記録を、フォルダの中の表（.ldb）と書き込みの控え（.log）から探す。
    /// 古い表は圧縮の掛け直しのあとも少し残ることがあるが、通し番号の大きい方が新しいので取り違えない
    static func latest(in dir: URL, matching match: ([UInt8]) -> Bool) -> Entry? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        var best: Entry?
        for file in files {
            let entry: Entry? =
                switch file.pathExtension {
                case "ldb": cached(file) { newest(in: table($0), matching: match) }
                case "log": cached(file) { newest(in: log($0), matching: match) }
                default: nil
                }
            if let entry, entry.sequence > (best?.sequence ?? 0) { best = entry }
        }
        return best
    }

    // MARK: - 読み直しを減らす

    /// 3秒ごとに見直すので、変わっていないファイルは読み直さない。表は1MBほどあり、
    /// ほとんど変わらない。書き込みの控えは Local Storage に書くたびに伸びる
    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }
    nonisolated(unsafe) private static var cache: [String: (Stamp, Entry?)] = [:]
    private static let lock = NSLock()

    private static func cached(_ file: URL, _ read: ([UInt8]) -> Entry?) -> Entry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            let modified = attributes[.modificationDate] as? Date,
            let size = attributes[.size] as? Int
        else { return nil }
        let stamp = Stamp(modified: modified, size: size)
        lock.lock()
        defer { lock.unlock() }
        if let (seen, entry) = cache[file.path], seen == stamp { return entry }
        guard let data = try? Data(contentsOf: file) else { return nil }
        let entry = read([UInt8](data))
        cache[file.path] = (stamp, entry)
        return entry
    }

    private static func newest(in records: [(key: [UInt8], entry: Entry)], matching match: ([UInt8]) -> Bool)
        -> Entry?
    {
        records.filter { match($0.key) }.max { $0.entry.sequence < $1.entry.sequence }?.entry
    }

    // MARK: - 書き込みの控え（.log）

    /// 32KB ごとの塊に、7バイトの頭（検査値4・長さ2・種類1）と中身が並ぶ。
    /// 種類は 1 が丸ごと、2・3・4 が分割した最初・途中・最後。中身は書き込みの束
    static func log(_ bytes: [UInt8]) -> [(key: [UInt8], entry: Entry)] {
        let blockSize = 32768
        var out: [(key: [UInt8], entry: Entry)] = []
        var i = 0
        var batch: [UInt8] = []
        while i + 7 <= bytes.count {
            let left = blockSize - i % blockSize
            if left < 7 {
                i += left
                continue
            }
            let length = Int(bytes[i + 4]) | Int(bytes[i + 5]) << 8
            let type = bytes[i + 6]
            let start = i + 7
            guard start + length <= bytes.count else { break }
            let fragment = bytes[start..<start + length]
            i = start + length
            switch type {
            case 1: batch = Array(fragment)
            case 2: batch = Array(fragment)
            case 3: batch += fragment
            case 4: batch += fragment
            default: continue
            }
            if type == 1 || type == 4 {
                out += writeBatch(batch)
                batch = []
            }
        }
        return out
    }

    /// 通し番号8バイト・件数4バイトのあとに、種類1バイト・鍵・（書き込みなら）値が並ぶ
    static func writeBatch(_ b: [UInt8]) -> [(key: [UInt8], entry: Entry)] {
        guard b.count >= 12 else { return [] }
        let sequence = littleEndian(b, 0, 8)
        let count = Int(littleEndian(b, 8, 4))
        var out: [(key: [UInt8], entry: Entry)] = []
        var i = 12
        for n in 0..<count {
            guard i < b.count else { break }
            let type = b[i]
            i += 1
            guard let key = slice(b, &i) else { break }
            var value: [UInt8] = []
            if type == 1 {
                guard let v = slice(b, &i) else { break }
                value = v
            }
            out.append((key, Entry(sequence: sequence + UInt64(n), type: type, value: value)))
        }
        return out
    }

    // MARK: - 表（.ldb）

    /// 末尾48バイトに、索引の塊の位置がある。索引の各項目が中身の塊の位置を指す
    static func table(_ bytes: [UInt8]) -> [(key: [UInt8], entry: Entry)] {
        guard bytes.count >= 48 else { return [] }
        var i = bytes.count - 48
        guard varint(bytes, &i) != nil, varint(bytes, &i) != nil,
            let indexOffset = varint(bytes, &i), let indexSize = varint(bytes, &i),
            let index = block(bytes, Int(indexOffset), Int(indexSize))
        else { return [] }
        var out: [(key: [UInt8], entry: Entry)] = []
        for (_, handle) in entries(index) {
            var j = 0
            guard let offset = varint(handle, &j), let size = varint(handle, &j),
                let data = block(bytes, Int(offset), Int(size))
            else { continue }
            for (key, value) in entries(data) where key.count >= 8 {
                // 鍵の末尾8バイトは、通し番号を8ビットずらして種類を足したもの
                let tag = littleEndian(key, key.count - 8, 8)
                out.append(
                    (Array(key.dropLast(8)), Entry(sequence: tag >> 8, type: UInt8(tag & 0xff), value: value)))
            }
        }
        return out
    }

    /// 塊の後ろに圧縮の種類1バイトと検査値4バイトが付く。種類は 0 が無圧縮、1 が Snappy
    private static func block(_ bytes: [UInt8], _ offset: Int, _ size: Int) -> [UInt8]? {
        guard offset >= 0, size >= 0, offset + size + 1 <= bytes.count else { return nil }
        let data = Array(bytes[offset..<offset + size])
        switch bytes[offset + size] {
        case 0: return data
        case 1: return Snappy.decompress(data)
        default: return nil
        }
    }

    /// 塊の中の項目。鍵は前の鍵と共通の頭を省いて並ぶ。末尾に再開点の一覧と、その数4バイトがある
    static func entries(_ b: [UInt8]) -> [(key: [UInt8], value: [UInt8])] {
        guard b.count >= 4 else { return [] }
        let restarts = Int(littleEndian(b, b.count - 4, 4))
        let end = b.count - 4 - restarts * 4
        guard end >= 0 else { return [] }
        var out: [(key: [UInt8], value: [UInt8])] = []
        var i = 0
        var key: [UInt8] = []
        while i < end {
            guard let shared = varint(b, &i), let unshared = varint(b, &i), let length = varint(b, &i),
                Int(shared) <= key.count, i + Int(unshared) + Int(length) <= end
            else { break }
            key = Array(key.prefix(Int(shared))) + b[i..<i + Int(unshared)]
            i += Int(unshared)
            out.append((key, Array(b[i..<i + Int(length)])))
            i += Int(length)
        }
        return out
    }

    // MARK: - 数の読み方

    static func varint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < b.count, shift < 64 {
            let byte = b[i]
            i += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }

    private static func slice(_ b: [UInt8], _ i: inout Int) -> [UInt8]? {
        guard let length = varint(b, &i), i + Int(length) <= b.count else { return nil }
        defer { i += Int(length) }
        return Array(b[i..<i + Int(length)])
    }

    private static func littleEndian(_ b: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(UInt64(0)) { $0 | UInt64(b[offset + $1]) << (8 * UInt64($1)) }
    }
}

/// Snappy の展開だけ。LevelDB の表の塊はこれで圧縮されている。Apple の Compression には無い
enum Snappy {
    static func decompress(_ b: [UInt8]) -> [UInt8]? {
        var i = 0
        guard let length = LevelDB.varint(b, &i), length < 1 << 28 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(Int(length))
        while i < b.count {
            let tag = b[i]
            i += 1
            switch tag & 3 {
            case 0:
                // 書き写す字の並び。長さが60以上なら、続く1〜4バイトに長さがある
                var count = Int(tag >> 2)
                if count >= 60 {
                    let bytes = count - 59
                    guard i + bytes <= b.count else { return nil }
                    count = (0..<bytes).reduce(0) { $0 | Int(b[i + $1]) << (8 * $1) }
                    i += bytes
                }
                count += 1
                guard i + count <= b.count else { return nil }
                out += b[i..<i + count]
                i += count
            default:
                // 前に出した字の並びを、何バイト前から何バイト写すか
                let count: Int
                let offset: Int
                switch tag & 3 {
                case 1:
                    guard i < b.count else { return nil }
                    count = Int((tag >> 2) & 7) + 4
                    offset = Int(tag >> 5) << 8 | Int(b[i])
                    i += 1
                case 2:
                    guard i + 2 <= b.count else { return nil }
                    count = Int(tag >> 2) + 1
                    offset = Int(b[i]) | Int(b[i + 1]) << 8
                    i += 2
                default:
                    guard i + 4 <= b.count else { return nil }
                    count = Int(tag >> 2) + 1
                    offset = (0..<4).reduce(0) { $0 | Int(b[i + $1]) << (8 * $1) }
                    i += 4
                }
                guard offset > 0, offset <= out.count else { return nil }
                // 写す元と写し先が重なることがある。1バイトずつ写す
                let start = out.count - offset
                for k in 0..<count { out.append(out[start + k]) }
            }
        }
        return out.count == Int(length) ? out : nil
    }
}
