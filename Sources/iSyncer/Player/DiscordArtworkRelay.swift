import AppKit
import CryptoKit
import Foundation

enum DiscordArtworkRelay {
    private static var hostedOrigin: String {
        Bundle.main.object(forInfoDictionaryKey: "DiscordArtworkRelayOrigin") as? String ?? ""
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    struct Cover: Sendable {
        let url: URL
        let renewAt: Date
    }

    private struct Lease: Decodable {
        let url: URL
        let expiresIn: Int
    }

    private struct Challenge: Decodable {
        let challenge: String
    }

    enum Failure: LocalizedError {
        case configuration, image, rejected(Int), invalidResponse

        var errorDescription: String? {
            switch self {
            case .configuration: return "Enter an HTTPS artwork relay and access token."
            case .image: return "The player cover could not be encoded."
            case .rejected(let code): return "Artwork relay returned HTTP \(code)."
            case .invalidResponse: return "Artwork relay returned an invalid cover link."
            }
        }
    }

    static func endpoint(_ input: String) -> URL? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        return url.appending(path: "covers")
    }

    @MainActor
    static func thumbnail(_ image: NSImage) throws -> Data {
        let side = 192
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.image }
        let scale = CGFloat(side) / CGFloat(min(source.width, source.height))
        let width = CGFloat(source.width) * scale
        let height = CGFloat(source.height) * scale
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2,
                                        width: width, height: height))
        guard let thumbnail = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: thumbnail).representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
              jpeg.count <= 64 * 1024 else { throw Failure.image }
        return jpeg
    }

    @MainActor
    static func publish(_ jpeg: Data, customOrigin: String, session: URLSession = URLSession.shared) async throws -> Cover {
        let custom = !customOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let endpoint = endpoint(custom ? customOrigin : hostedOrigin) else { throw Failure.configuration }
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.httpMethod = "POST"
        if custom {
            guard let token = CredentialStore.read("discord.artworkRelayToken"), !token.isEmpty else {
                throw Failure.configuration
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            let challengeURL = endpoint.deletingLastPathComponent().appending(path: "challenge")
            let challengeRequest = URLRequest(url: challengeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            let challengeData = try await responseData(for: challengeRequest, expecting: 200, session: session)
            guard let challenge = try? JSONDecoder().decode(Challenge.self, from: challengeData),
                  challenge.challenge.utf8.count == 112 else { throw Failure.invalidResponse }
            let proof = try await solve(challenge.challenge)
            request.setValue(challenge.challenge, forHTTPHeaderField: "X-Artwork-Challenge")
            request.setValue(proof, forHTTPHeaderField: "X-Artwork-Proof")
        }
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        let data = try await responseData(for: request, expecting: 201, session: session)
        guard let lease = try? JSONDecoder().decode(Lease.self, from: data),
              lease.url.scheme == "https", lease.url.host() == endpoint.host(), lease.url.port == endpoint.port,
              lease.url.user == nil, lease.url.password == nil, lease.url.query == nil, lease.url.fragment == nil,
              lease.url.path.hasPrefix("/covers/"), lease.url.pathExtension == "jpg",
              (60...600).contains(lease.expiresIn) else { throw Failure.invalidResponse }
        return Cover(url: lease.url, renewAt: Date().addingTimeInterval(Double(lease.expiresIn - 45)))
    }

    private static func solve(_ challenge: String) async throws -> String {
        let task = Task.detached(priority: .utility) {
            for nonce in 0..<2_000_000 {
                if nonce.isMultiple(of: 1024) { try Task.checkCancellation() }
                let digest = SHA256.hash(data: Data("\(challenge):\(nonce)".utf8))
                if digest.prefix(2).allSatisfy({ $0 == 0 }) { return String(nonce) }
            }
            throw Failure.invalidResponse
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func responseData(for request: URLRequest, expecting status: Int, session: URLSession) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request, delegate: RejectRedirects())
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard http.statusCode == status else { throw Failure.rejected(http.statusCode) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4096 else { throw Failure.invalidResponse }
            data.append(byte)
        }
        return data
    }
}
