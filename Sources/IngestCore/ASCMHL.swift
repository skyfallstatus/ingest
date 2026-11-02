import CryptoKit
import Foundation

/// ASC MHL v2.0 manifest beside the media, so any pro tool can re-verify the copy without this app.
/// `write` appends to a history it finds in `root`, and never overwrites one.
enum ASCMHL {
    struct Row: Sendable {
        var path: String; public var size: UInt64; public var mtime: Int64; public var hash: String
        init(path: String, size: UInt64, mtime: Int64, hash: String) {
            self.path = path; self.size = size; self.mtime = mtime; self.hash = hash
        }
    }

    static func c4(_ data: Data) -> String {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        var digits = Array(SHA512.hash(data: data))
        var out: [Character] = []
        var start = 0
        while start < digits.count {
            var rem = 0
            for i in start..<digits.count {
                let acc = rem * 256 + Int(digits[i])
                digits[i] = UInt8(acc / 58)
                rem = acc % 58
            }
            out.append(alphabet[rem])
            while start < digits.count && digits[start] == 0 { start += 1 }
        }
        while out.count < 88 { out.append("1") }
        return "c4" + String(out.reversed())
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// `root` is the absolute folder the manifest describes. Paths in `rows` are relative to it, in readdir form.
    @discardableResult
    static func write(root: String, rows: [Row], now: Date = Date()) throws -> String {
        let folder = root + "/ascmhl"
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let chainPath = folder + "/ascmhl_chain.xml"
        let existingChain = fm.contents(atPath: chainPath).flatMap { String(data: $0, encoding: .utf8) }

        var sequence = 1
        if let existingChain {
            let re = try NSRegularExpression(pattern: "sequencenr=\"(\\d+)\"")
            let ns = existingChain as NSString
            let found = re.matches(in: existingChain, range: NSRange(location: 0, length: ns.length))
                .compactMap { Int(ns.substring(with: $0.range(at: 1))) }
            sequence = (found.max() ?? 0) + 1
        }
        let stamp = iso(now)
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
          <creatorinfo>
            <creationdate>\(stamp)</creationdate>
            <hostname>\(escape(ProcessInfo.processInfo.hostName))</hostname>
            <tool version="\(AppInfo.version)">\(escape(AppInfo.name))</tool>
          </creatorinfo>
          <processinfo>
            <process>transfer</process>
            <ignore>
              <pattern>.DS_Store</pattern>
              <pattern>ascmhl</pattern>
              <pattern>ascmhl/</pattern>
              <pattern>._*</pattern>
            </ignore>
          </processinfo>
          <hashes>

        """
        for r in rows {
            let m = iso(Date(timeIntervalSince1970: TimeInterval(r.mtime)))
            x += "    <hash>\n      <path size=\"\(r.size)\" lastmodificationdate=\"\(m)\">\(escape(r.path))</path>\n"
            x += "      <xxh64 action=\"original\" hashdate=\"\(stamp)\">\(r.hash)</xxh64>\n    </hash>\n"
        }
        x += "  </hashes>\n</hashlist>\n"

        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX"); utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyy-MM-dd_HHmmss'Z'"
        let folderName = (root as NSString).lastPathComponent
        let name = String(format: "%04d", sequence) + "_\(folderName)_\(utc.string(from: now)).mhl"
        let data = Data(x.utf8)
        guard fm.createFile(atPath: folder + "/" + name, contents: data) else { throw IngestError.driveNotWritable(root) }

        let row = "  <hashlist sequencenr=\"\(sequence)\">\n    <path>\(escape(name))</path>\n    <c4>\(c4(data))</c4>\n  </hashlist>\n"
        let chain: String
        if let existingChain, let end = existingChain.range(of: "</ascmhldirectory>") {
            chain = existingChain.replacingCharacters(in: end, with: row + "</ascmhldirectory>")
        } else {
            chain = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ascmhldirectory xmlns=\"urn:ASC:MHL:DIRECTORY:v2.0\">\n\(row)</ascmhldirectory>\n"
        }
        try Data(chain.utf8).write(to: URL(fileURLWithPath: chainPath), options: .atomic)
        for f in [name, "ascmhl_chain.xml"] { unlink(folder + "/._" + f) }
        unlink(root + "/._ascmhl")
        return folder + "/" + name
    }
}
