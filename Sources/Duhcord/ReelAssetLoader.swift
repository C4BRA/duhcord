import AVFoundation
import Foundation
import UniformTypeIdentifiers

final class ReelAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    typealias Fetch = @Sendable (Int, @escaping @Sendable (Data?) -> Void) -> (@Sendable () -> Void)

    private final class Flight {
        let cancel: @Sendable () -> Void

        init(cancel: @escaping @Sendable () -> Void) {
            self.cancel = cancel
        }
    }

    private final class Delivery: @unchecked Sendable {
        private weak var loader: ReelAssetLoader?
        private let index: Int

        init(loader: ReelAssetLoader, index: Int) {
            self.loader = loader
            self.index = index
        }

        func send(_ data: Data?) {
            loader?.complete(index, data: data)
        }
    }

    private let lengths: [Int]
    private let offsets: [Int]
    private let totalLength: Int
    private let fetch: Fetch
    private let queue = DispatchQueue(label: "duhcord.reel-resource-loader")
    private var requests: [ObjectIdentifier: AVAssetResourceLoadingRequest] = [:]
    private var flights: [Int: Flight] = [:]
    private var cache: [Int: Data] = [:]
    private var leastRecent: [Int] = []
    private var cancelled = false

    init(lengths: [Int], fetch: @escaping Fetch) {
        var offsets: [Int] = []
        var total = 0
        var valid = !lengths.isEmpty && lengths.allSatisfy { $0 > 0 }
        for length in lengths where valid {
            offsets.append(total)
            let (next, overflow) = total.addingReportingOverflow(length)
            valid = !overflow
            total = next
        }
        self.lengths = valid ? lengths : []
        self.offsets = valid ? offsets : []
        totalLength = valid ? total : 0
        self.fetch = fetch
        super.init()
    }

    func makeAsset() -> AVURLAsset {
        let url = URL(string: "duhcord-reel://\(UUID().uuidString)/video.mp4")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !cancelled, totalLength > 0 else {
            loadingRequest.finishLoading(with: URLError(.cannotDecodeContentData))
            return true
        }
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = UTType.mpeg4Movie.identifier
            information.contentLength = Int64(totalLength)
            information.isByteRangeAccessSupported = true
        }
        guard loadingRequest.dataRequest != nil else {
            loadingRequest.finishLoading()
            return true
        }
        requests[ObjectIdentifier(loadingRequest)] = loadingRequest
        service(loadingRequest)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        requests[ObjectIdentifier(loadingRequest)] = nil
    }

    func cancelAll() {
        queue.async {
            self.cancelled = true
            let flights = self.flights.values
            self.flights = [:]
            for flight in flights { flight.cancel() }
            let requests = self.requests.values
            self.requests = [:]
            for request in requests { request.finishLoading(with: URLError(.cancelled)) }
            self.cache = [:]
            self.leastRecent = []
        }
    }

    private func service(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard let request = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            requests[ObjectIdentifier(loadingRequest)] = nil
            return
        }
        let start = max(request.requestedOffset, request.currentOffset)
        guard start >= 0, start <= Int64(totalLength) else {
            fail(loadingRequest, with: URLError(.badURL))
            return
        }
        let end: Int64
        if request.requestsAllDataToEndOfResource {
            end = Int64(totalLength)
        } else {
            let (requestedEnd, overflow) = request.requestedOffset
                .addingReportingOverflow(Int64(request.requestedLength))
            guard !overflow else {
                fail(loadingRequest, with: URLError(.badURL))
                return
            }
            end = min(Int64(totalLength), requestedEnd)
        }
        guard start <= end else {
            fail(loadingRequest, with: URLError(.badURL))
            return
        }
        if start == end {
            finish(loadingRequest)
            return
        }
        guard let index = offsets.indices.first(where: { start < Int64(offsets[$0] + lengths[$0]) }) else {
            fail(loadingRequest, with: URLError(.badURL))
            return
        }
        prefetch(index + 1)
        guard let data = cached(index) else {
            prefetch(index)
            return
        }
        let chunkStart = Int64(offsets[index])
        let lower = Int(start - chunkStart)
        let upper = Int(min(end, chunkStart + Int64(lengths[index])) - chunkStart)
        request.respond(with: data.subdata(in: lower..<upper))
        service(loadingRequest)
    }

    private func prefetch(_ index: Int) {
        guard !cancelled, lengths.indices.contains(index), cache[index] == nil, flights[index] == nil else { return }
        let delivery = Delivery(loader: self, index: index)
        let completionQueue = queue
        let cancel = fetch(index) { data in
            completionQueue.async { delivery.send(data) }
        }
        flights[index] = Flight(cancel: cancel)
    }

    private func complete(_ index: Int, data: Data?) {
        guard !cancelled, flights.removeValue(forKey: index) != nil else { return }
        guard let data, data.count == lengths[index] else {
            let requests = self.requests.values
            self.requests = [:]
            for request in requests { request.finishLoading(with: URLError(.cannotDecodeContentData)) }
            return
        }
        cache[index] = data
        leastRecent.removeAll { $0 == index }
        leastRecent.append(index)
        while leastRecent.count > 3 {
            cache[leastRecent.removeFirst()] = nil
        }
        for request in requests.values { service(request) }
    }

    private func cached(_ index: Int) -> Data? {
        guard let data = cache[index] else { return nil }
        leastRecent.removeAll { $0 == index }
        leastRecent.append(index)
        return data
    }

    private func finish(_ request: AVAssetResourceLoadingRequest) {
        requests[ObjectIdentifier(request)] = nil
        request.finishLoading()
    }

    private func fail(_ request: AVAssetResourceLoadingRequest, with error: Error) {
        requests[ObjectIdentifier(request)] = nil
        request.finishLoading(with: error)
    }
}
