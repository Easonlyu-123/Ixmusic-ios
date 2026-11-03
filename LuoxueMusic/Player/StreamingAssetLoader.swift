import AVFoundation

/// 通过 `AVAssetResourceLoader` 拦截音频资源的网络请求，注入自定义请求头（Referer / Cookie / UA），
/// 再原样把字节喂给 AVPlayer。
///
/// 洛雪各平台音频 CDN（网易云 / 酷我 / QQ）直链普遍要求带 `Referer` 才能返回音频；
/// 但 `AVPlayer` / `AVURLAsset` 默认发起的请求不带这些头，导致 403 / 返回 HTML，
/// 表现为「页面能打开、但放不出声音、进度也不动」。本类把裸直链改写成自定义 scheme，
/// 由我们自己的 `URLSession` 带上头去拉流，从而兼容各 CDN。
final class StreamingAssetLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {

    /// 自定义 scheme：音频直链会被改写成 `lxstream://...`，触发本 loader 接管。
    static let scheme = "lxstream"

    let headers: [String: String]
    private let session: URLSession
    private var pending: [URLSessionTask: AVAssetResourceLoadingRequest] = [:]
    private let lock = NSLock()

    init(headers: [String: String] = [:]) {
        self.headers = headers
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        super.init()
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// 把普通直链包装成由本 loader 接管的 asset。
    static func makeAsset(url: URL, headers: [String: String]) -> (asset: AVURLAsset, loader: StreamingAssetLoader) {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.scheme = Self.scheme
        let asset = AVURLAsset(url: comps.url!)
        let loader = StreamingAssetLoader(headers: headers)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "lx.asset.loader"))
        return (asset, loader)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: NSError(domain: "lx", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效音频地址"]))
            return true
        }
        var realURL = url
        if url.scheme == Self.scheme, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.scheme = "https"
            if let u = comps.url { realURL = u }
        }
        var req = URLRequest(url: realURL, timeoutInterval: 30)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        // AVPlayer 常发起字节范围请求（拖动 / 边下边播），把 Range 透传给 CDN。
        if let dr = loadingRequest.dataRequest, !dr.requestsAllDataToEndOfResource {
            let start = dr.requestedOffset
            let end = start + Int64(dr.requestedLength) - 1
            if start <= end {
                req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            }
        }
        let task = session.dataTask(with: req)
        lock.lock(); pending[task] = loadingRequest; lock.unlock()
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForResponseToAuthenticationChallenge challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); let req = pending[dataTask]; lock.unlock()
        guard let req, let cir = req.contentInformationRequest else { completionHandler(.allow); return }
        if let http = response as? HTTPURLResponse {
            cir.contentType = http.mimeType ?? "audio/mpeg"
            cir.contentLength = http.expectedContentLength
            cir.isByteRangeAccessSupported = (http.value(forHTTPHeaderField: "Accept-Ranges")?.contains("bytes") ?? false) || http.statusCode == 206
        } else {
            cir.contentType = response.mimeType ?? "audio/mpeg"
            cir.contentLength = response.expectedContentLength
        }
        cir.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let req = pending[dataTask]; lock.unlock()
        req?.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let req = pending[task]; pending[task] = nil; lock.unlock()
        guard let req else { return }
        if let error {
            req.finishLoading(with: error)
        } else {
            req.finishLoading()
        }
    }

    /// 跟随 302 重定向时保留注入的请求头（例如网易云外链 302 到 CDN 仍需 Referer）。
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var r = request
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        completionHandler(r)
    }

    /// 停止并断开 session。URLSession 强引用其 delegate（即本 loader），不主动失效会造成循环引用泄漏。
    func invalidate() {
        session.invalidateAndCancel()
    }
}
