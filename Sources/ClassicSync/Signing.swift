import CommonCrypto
import CryptoKit
import Foundation

// On-disk signing algorithms documented by libgpod's itdb_hash58.c and itdb_hash72.c.
struct Signing {
    private let key: SymmetricKey
    private let hash72: Hash72?

    init(database: Data, guid: Data) throws {
        try self.init(database: database, guid: guid, verifiesSignature: true)
    }

    static func signEmptyDatabase(_ database: inout Data, guid: Data) throws {
        guard try Database(database).tracks.isEmpty, database.count >= 0xa0,
              database.subdata(in: 0x58..<0x6c).allSatisfy({ $0 == 0 }) else {
            throw SyncError("Only a new, empty iTunesDB can be signed without a prior signature.")
        }
        try Signing(database: database, guid: guid, verifiesSignature: false).sign(&database)
    }

    private init(database: Data, guid: Data, verifiesSignature: Bool) throws {
        guard guid.count == 8, database.count >= 0xa0, database.u16(0x30) == 1 else {
            throw SyncError("This database does not use the Classic's HASH58 format.")
        }
        var seed = Data([0x67, 0x23, 0xfe, 0x30, 0x45, 0x33, 0xf8, 0x90, 0x99,
                         0x21, 0x07, 0xc1, 0xd0, 0x12, 0xb2, 0xa1, 0x07, 0x81])
        for index in stride(from: 0, to: guid.count, by: 2) {
            let first = Int(guid[index])
            let second = Int(guid[index + 1])
            let lcm = first == 0 || second == 0 ? 1 : first * second / Self.gcd(first, second)
            for byte in [lcm >> 8, lcm & 255] {
                seed.append(Self.substitution[byte])
                seed.append(Self.inverseSubstitution[byte])
            }
        }
        key = SymmetricKey(data: Insecure.SHA1.hash(data: seed))
        hash72 = try Hash72.read(from: database)
        guard !verifiesSignature || signature(for: database) == database.subdata(in: 0x58..<0x6c) else {
            throw SyncError("The current iTunesDB signature does not match this iPod.")
        }
    }

    func sign(_ database: inout Data) throws {
        if let hash72 {
            database.replaceSubrange(0x72..<0xa0, with: try hash72.signature(for: database))
        }
        database.replaceSubrange(0x58..<0x6c, with: signature(for: database))
    }

    private func signature(for database: Data) -> Data {
        var input = database
        input.resetBytes(in: 0x18..<0x20)
        input.resetBytes(in: 0x32..<0x46)
        input.resetBytes(in: 0x58..<0x6c)
        return Data(HMAC<Insecure.SHA1>.authenticationCode(for: input, using: key))
    }

    private static func gcd(_ first: Int, _ second: Int) -> Int {
        var a = first
        var b = second
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    private static func product(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var left = a
        var right = b
        var result: UInt8 = 0
        while right != 0 {
            if right & 1 != 0 { result ^= left }
            let reduction: UInt8 = left & 0x80 == 0 ? 0 : 0x1b
            left = (left << 1) ^ reduction
            right >>= 1
        }
        return result
    }

    private static let substitution: [UInt8] = (0...255).map { value in
        let inverse = (1...255).lazy.map(UInt8.init).first { product(UInt8(value), $0) == 1 } ?? 0
        return (1...4).reduce(inverse ^ 0x63) { result, shift in
            result ^ ((inverse << shift) | (inverse >> (8 - shift)))
        }
    }

    private static let inverseSubstitution: [UInt8] = {
        var inverse = [UInt8](repeating: 0, count: 256)
        for (index, value) in substitution.enumerated() { inverse[Int(value)] = UInt8(index) }
        return inverse
    }()
}

private struct Hash72 {
    private static let key: [UInt8] = [0x61, 0x8c, 0xa1, 0x0d, 0xc7, 0xf5, 0x7f, 0xd3,
                                       0xb4, 0x72, 0x3e, 0x08, 0x15, 0x74, 0x63, 0xd7]
    let iv: [UInt8]
    let random: Data
    let clearReservedField: Bool

    static func read(from database: Data) throws -> Self? {
        let original = database.subdata(in: 0x72..<0xa0)
        guard original.starts(with: [1, 0]) else { return nil }
        let random = original.subdata(in: 2..<14)
        let encrypted = original.subdata(in: 14..<46)
        let decrypted = try aes(kCCDecrypt, input: encrypted, iv: [UInt8](repeating: 0, count: 16))
        for clearReserved in [false, true] {
            let hash = digest(database, clearReserved: clearReserved)
            let expected = hash + random
            guard decrypted.suffix(16) == expected.suffix(16) else { continue }
            let iv = zip(decrypted.prefix(16), expected.prefix(16)).map { $0.0 ^ $0.1 }
            return Self(iv: iv, random: random, clearReservedField: clearReserved)
        }
        return nil
    }

    func signature(for database: Data) throws -> Data {
        let plaintext = Self.digest(database, clearReserved: clearReservedField) + random
        return Data([1, 0]) + random + (try Self.aes(kCCEncrypt, input: plaintext, iv: iv))
    }

    private static func digest(_ database: Data, clearReserved: Bool) -> Data {
        var input = database
        input.resetBytes(in: 0x18..<0x20)
        if clearReserved { input.resetBytes(in: 0x32..<0x46) }
        input.resetBytes(in: 0x58..<0x6c)
        input.resetBytes(in: 0x72..<0xa0)
        return Data(Insecure.SHA1.hash(data: input))
    }

    private static func aes(_ operation: Int, input: Data, iv: [UInt8]) throws -> Data {
        var output = [UInt8](repeating: 0, count: input.count)
        let capacity = output.count
        var written = 0
        let status = input.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), 0,
                    key, key.count, iv, bytes.baseAddress, bytes.count, &output, capacity, &written)
        }
        guard status == kCCSuccess, written == input.count else {
            throw SyncError("Could not prepare the database's secondary signature.")
        }
        return Data(output)
    }
}
