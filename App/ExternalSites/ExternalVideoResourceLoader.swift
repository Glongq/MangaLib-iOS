import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Bridges AVFoundation byte requests to HTTP with the source's public headers.
/// Data is streamed to the player; it is never accumulated as a whole movie.
final class ExternalVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private final class Transfer {
        let loading: AVAssetResourceLoadingRequest
        let task: URLSessionDataTask
        let start: Int64
        let end: Int64?
        var streamOffset: Int64 = 0
        var total: Int64?

        init(loading: AVAssetResourceLoadingRequest, task: URLSessionDataTask, start: Int64, end: Int64?) {
            self.loading = loading
            self.task = task
            self.start = start
            self.end = end
        }
    }

    private let video: ExternalVideo
    private let queue = DispatchQueue(label: "external.video.http")
    private var transfers: [Int: Transfer] = [:]
    private var invalidated = false
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    init(video: ExternalVideo) { self.video = video }

    func makeAsset() -> AVURLAsset {
        var components = URLComponents(url: video.url, resolvingAgainstBaseURL: false)!
        components.scheme = "external-video"
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func invalidate() {
        queue.async { [self] in
            guard !invalidated else { return }
            invalidated = true
            let pending = Array(transfers.values)
            transfers.removeAll()
            for transfer in pending {
                transfer.task.cancel()
                if !transfer.loading.isCancelled && !transfer.loading.isFinished {
                    transfer.loading.finishLoading(with: URLError(.cancelled))
                }
            }
            session.invalidateAndCancel()
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !invalidated else { return false }
        let data = loadingRequest.dataRequest
        let start = max(data?.requestedOffset ?? 0, data?.currentOffset ?? 0)
        let end: Int64?
        if let data, !data.requestsAllDataToEndOfResource {
            end = data.requestedOffset + Int64(data.requestedLength)
        } else {
            end = data == nil ? 2 : nil
        }
        var request = URLRequest(url: video.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        for (name, value) in video.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let upper = end.map { String(max(start, $0 - 1)) } ?? ""
        request.setValue("bytes=\(start)-\(upper)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        transfers[task.taskIdentifier] = Transfer(loading: loadingRequest, task: task, start: start, end: end)
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let transfer = transfers.values.first(where: { $0.loading === loadingRequest }) else { return }
        transfers.removeValue(forKey: transfer.task.taskIdentifier)
        transfer.task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfers[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        let mime = (response.mimeType ?? "").lowercased()
        guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
              mime.hasPrefix("video/") || mime == "application/octet-stream" else {
            completionHandler(.cancel)
            finish(transfer, error: URLError(.badServerResponse))
            return
        }
        if http.statusCode == 206 {
            guard let header = http.value(forHTTPHeaderField: "Content-Range"),
                  let space = header.firstIndex(of: " "),
                  let slash = header.lastIndex(of: "/"),
                  let dash = header[space..<slash].firstIndex(of: "-"),
                  let lower = Int64(header[header.index(after: space)..<dash]),
                  let total = Int64(header[header.index(after: slash)...]), lower <= transfer.start else {
                completionHandler(.cancel)
                finish(transfer, error: URLError(.badServerResponse))
                return
            }
            transfer.streamOffset = lower
            transfer.total = total
        } else {
            transfer.streamOffset = 0
            transfer.total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        }
        if let info = transfer.loading.contentInformationRequest {
            info.contentType = UTType(mimeType: response.mimeType ?? "video/mp4")?.identifier ?? UTType.mpeg4Movie.identifier
            info.contentLength = transfer.total ?? 0
            info.isByteRangeAccessSupported = http.statusCode == 206
                || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        }
        if transfer.loading.dataRequest == nil {
            completionHandler(.cancel)
            finish(transfer)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfers[dataTask.taskIdentifier], let request = transfer.loading.dataRequest else { return }
        guard !transfer.loading.isCancelled else { finish(transfer, error: URLError(.cancelled)); return }
        let wanted = max(request.currentOffset, request.requestedOffset)
        let skip = max(0, wanted - transfer.streamOffset)
        let remaining = transfer.end.map { max(0, $0 - wanted) } ?? Int64(data.count)
        if skip < Int64(data.count), remaining > 0 {
            let length = min(Int64(data.count) - skip, remaining)
            request.respond(with: data.subdata(in: Int(skip)..<Int(skip + length)))
        }
        transfer.streamOffset += Int64(data.count)
        if let end = transfer.end, request.currentOffset >= end {
            finish(transfer)
        } else if let total = transfer.total, request.currentOffset >= total {
            finish(transfer)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfers[task.taskIdentifier] else { return }
        let received = transfer.loading.dataRequest?.currentOffset ?? 0
        let expected = transfer.end.map { min($0, transfer.total ?? $0) } ?? transfer.total
        if let error { finish(transfer, error: error) }
        else if let expected, received < expected { finish(transfer, error: URLError(.networkConnectionLost)) }
        else { finish(transfer) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        let sameOrigin = request.url?.scheme == video.url.scheme && request.url?.host == video.url.host
            && (request.url?.port ?? 443) == (video.url.port ?? 443)
        if !sameOrigin {
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        redirected.httpShouldHandleCookies = false
        completionHandler(redirected)
    }

    private func finish(_ transfer: Transfer, error: Error? = nil) {
        guard transfers.removeValue(forKey: transfer.task.taskIdentifier) != nil else { return }
        transfer.task.cancel()
        guard !transfer.loading.isCancelled && !transfer.loading.isFinished else { return }
        if let error { transfer.loading.finishLoading(with: error) }
        else { transfer.loading.finishLoading() }
    }
}
