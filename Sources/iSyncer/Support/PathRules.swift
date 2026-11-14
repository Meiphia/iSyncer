import Foundation

/// Device-side naming: FAT-safe, deterministic, collision-free.
enum PathRules {
    private static let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)

    /// Makes one path component safe for FAT32/exFAT.
    static func sanitize(_ component: String, maxLength: Int = 120) -> String {
        var s = String(String.UnicodeScalarView(component.unicodeScalars.map { illegal.contains($0) ? "_" : $0 }))
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix(".") { s.removeLast() }
        while s.hasPrefix(".") { s.removeFirst() }   // leading dots would hide the file in Rockbox
        if s.isEmpty { s = "_" }
        if s.count > maxLength {
            let ext = (s as NSString).pathExtension
            let base = (s as NSString).deletingPathExtension
            let keep = maxLength - (ext.isEmpty ? 0 : ext.count + 1)
            s = String(base.prefix(max(1, keep))).trimmingCharacters(in: .whitespaces)
            if !ext.isEmpty { s += "." + ext }
        }
        return s
    }

    static func sanitizePath(_ path: String) -> String {
        path.split(separator: "/").map { sanitize(String($0)) }.joined(separator: "/")
    }

    /// Stable 64-bit FNV-1a, for content signatures and cache keys.
    static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}
