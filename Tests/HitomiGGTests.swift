import Foundation

enum HitomiError: Error { case badResponse, decodingFailed }

private final class RoutingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()
    private static var requests = 0

    static func configure(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        body = Data(text.utf8)
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let data = Self.body
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct HitomiGGTests {
    static func fixture(defaultValue: Int, caseValue: Int, path: String = "1792090801/") -> String {
        """
        'use strict'; gg = { m: function(g) {
          var o = \(defaultValue); switch (g) { case 2748: case 1: o = \(caseValue); break; }
          return o;
        }, s: function(h) { return h; }, b: '\(path)' };
        """
    }

    static func main() async throws {
        let inside = String(repeating: "0", count: 61) + "bca"
        let outside = String(repeating: "0", count: 64)
        let oldScript = fixture(defaultValue: 0, caseValue: 1)
        let newScript = fixture(defaultValue: 1, caseValue: 0)
        let old = HitomiGG.parse(oldScript)!
        let new = HitomiGG.parse(newScript)!
        precondition(HitomiGG.s(inside) == "2748", "Hash buckets must preserve Hitomi's byte permutation")
        precondition(old.imageURL(for: inside)?.host == "a2.gold-usergeneratedcontent.net")
        precondition(old.imageURL(for: outside)?.host == "a1.gold-usergeneratedcontent.net")
        precondition(new.imageURL(for: inside)?.host == "a1.gold-usergeneratedcontent.net")
        precondition(new.imageURL(for: outside)?.host == "a2.gold-usergeneratedcontent.net")
        precondition(new.imageURL(for: inside)?.path == "/1792090801/2748/\(inside).avif")
        precondition(new.imageURL(for: "invalid") == nil)
        precondition(HitomiGG.parse(newScript.replacingOccurrences(of: "o = 0; break;", with: "break;")) == nil,
                     "Unknown routing scripts must fail instead of guessing a server")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RoutingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let cache = HitomiGGCache()
        RoutingURLProtocol.configure(oldScript)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let configuration = try await cache.current(session: session)
                    precondition(configuration.defaultValue == 0)
                }
            }
            try await group.waitForAll()
        }
        precondition(RoutingURLProtocol.requestCount == 1, "Concurrent reader pages must share one routing request")
        let failedURL = old.imageURL(for: inside)!
        RoutingURLProtocol.configure(fixture(defaultValue: 1, caseValue: 0, path: "1792094401/"))
        await cache.invalidate(failedURL: failedURL, hash: inside)
        let refreshed = try await cache.current(session: session)
        precondition(refreshed.b == "1792094401/" && refreshed.defaultValue == 1)
        precondition(RoutingURLProtocol.requestCount == 2, "A failed image must allow a fresh routing configuration")
        await cache.invalidate(failedURL: failedURL, hash: inside)
        _ = try await cache.current(session: session)
        precondition(RoutingURLProtocol.requestCount == 2, "A late failure of an old URL must not invalidate fresh routing")

        if let path = CommandLine.arguments.dropFirst().first { try verifyHAR(path) }
        print("Hitomi CDN routing: all checks passed")
    }

    static func verifyHAR(_ path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let entries = (root["log"] as! [String: Any])["entries"] as! [[String: Any]]
        var configuration: HitomiGG.Configuration?
        var images = Set<URL>()
        for entry in entries {
            let request = entry["request"] as! [String: Any]
            guard let url = URL(string: request["url"] as! String) else { continue }
            if url.path == "/gg.js" {
                let content = (entry["response"] as! [String: Any])["content"] as! [String: Any]
                if let text = content["text"] as? String {
                    let script = (content["encoding"] as? String) == "base64"
                        ? String(data: Data(base64Encoded: text) ?? Data(), encoding: .utf8) : text
                    if let script { configuration = HitomiGG.parse(script) }
                }
            }
            if ["a1.gold-usergeneratedcontent.net", "a2.gold-usergeneratedcontent.net"].contains(url.host ?? "") {
                images.insert(url)
            }
        }
        precondition(configuration != nil && !images.isEmpty, "HAR must contain routing and reader image requests")
        for image in images {
            let hash = image.deletingPathExtension().lastPathComponent
            precondition(configuration?.imageURL(for: hash) == image, "Generated reader URL must match the captured request")
        }
        print("HAR compatibility: \(images.count)/\(images.count) reader image URLs match")
    }
}
