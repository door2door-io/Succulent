import Embassy

public class Succulent {
    
    public var port: Int?
    public var version = 0
    public var passThroughBaseURL: URL?
    public var recordBaseURL: URL?
    
    public let router = Matching()
    
    private let bundle: Bundle
    
    private var loop: EventLoop!
    private var server: DefaultHTTPServer!
    
    private var loopThreadCondition: NSCondition!
    private var loopThread: Thread!
    
    private var lastWasMutation = false
    
    private lazy var session = URLSession(configuration: .default)
    
    public var actualPort: Int {
        return server.listenAddress.port
    }
    
    public init(bundle: Bundle) {
        self.bundle = bundle
        
        router.add(".*").anyParams().block { (req, resultBlock) in
            /* Increment version when we get the first GET after a mutating http method */
            if req.method != "GET" && req.method != "HEAD" {
                self.lastWasMutation = true
            } else if self.lastWasMutation {
                self.version += 1
                self.lastWasMutation = false
            }
            
            if let url = self.url(for: req.path, queryString: req.queryString, method: req.method) {
                let data = try! Data(contentsOf: url)
                
                var status = ResponseStatus.ok
                var headers: [(String, String)]?
                
                if let headersUrl = self.url(for: req.path, queryString: req.queryString, method: req.method, replaceExtension: "head") {
                    if let headerData = try? Data(contentsOf: headersUrl) {
                        let (aStatus, aHeaders) = self.parseHeaderData(data: headerData)
                        status = aStatus
                        headers = aHeaders
                    }
                }
                
                if headers == nil {
                    let contentType = self.contentType(for: url)
                    headers = [("Content-Type", contentType)]
                }
                
                var res = Response(status: status)
                res.headers = headers
                
                res.data = data
                resultBlock(.response(res))
            } else if let passThroughBaseURL = self.passThroughBaseURL {
                let url = URL(string: req.path, relativeTo: passThroughBaseURL)!
                print("Pass-through URL: \(url.absoluteURL)")
                
                let dataTask = self.session.dataTask(with: url) { (data, response, error) in
                    let response = response as! HTTPURLResponse
                    let statusCode = response.statusCode
                    
                    var res = Response(status: .other(code: statusCode))
                    
                    var headers = [(String, String)]()
                    for header in response.allHeaderFields {
                        let key = (header.key as! String)
                        if Succulent.dontPassThroughHeaders[key.lowercased()] ?? false {
                            continue
                        }
                        headers.append((key, header.value as! String))
                    }
                    res.headers = headers
                    
                    try! self.record(for: req.path, queryString: req.queryString, method: req.method, data: data, response: response)
                    
                    res.data = data
                    
                    resultBlock(.response(res))
                }
                dataTask.resume()
            } else {
                resultBlock(.response(Response(status: .notFound)))
            }
        }
    }
    
    private func parseHeaderData(data: Data) -> (ResponseStatus, [(String, String)]) {
        let lines = String(data: data, encoding: .utf8)!.components(separatedBy: "\r\n")
        let statusCode = ResponseStatus.other(code: Int(lines[0])!)
        var headers = [(String, String)]()
        
        for line in lines.dropFirst() {
            if let r = line.range(of: ": ") {
                let key = line.substring(to: r.lowerBound)
                let value = line.substring(from: r.upperBound)
                
                if Succulent.dontPassThroughHeaders[key.lowercased()] ?? false {
                    continue
                }
                headers.append((key, value))
            }
        }
        
        return (statusCode, headers)
    }
    
    private static let dontPassThroughHeaders = ["content-encoding": true, "content-length": true, "connection": true, "keep-alive": true]
    
    private func createRequest(environ: [String: Any]) -> Request {
        let method = environ["REQUEST_METHOD"] as! String
        let path = environ["PATH_INFO"] as! String
        
        var req = Request(method: method, path: path)
        req.queryString = environ["QUERY_STRING"] as? String
        
        var headers = [(String, String)]()
        for pair in environ {
            if pair.key.hasPrefix("HTTP_"), let value = pair.value as? String {
                let key = pair.key.substring(from: pair.key.index(pair.key.startIndex, offsetBy: 5))
                headers.append((key, value))
            }
        }
        req.headers = headers
        
        return req
    }
    
    public func start() {
        loop = try! SelectorEventLoop(selector: try! KqueueSelector())
        
        let app: SWSGI = {
            (
            environ: [String: Any],
            startResponse: @escaping ((String, [(String, String)]) -> Void),
            sendBody: @escaping ((Data) -> Void)
            ) in
            
            let method = environ["REQUEST_METHOD"] as! String
            let path = environ["PATH_INFO"] as! String
            let queryString = environ["QUERY_STRING"] as? String
            
            let req = self.createRequest(environ: environ)
            self.router.handle(request: req) { result in
                self.loop.call {
                    switch result {
                    case .response(let res):
                        startResponse("\(res.status)", res.headers ?? [])
                        
                        if let data = res.data {
                            sendBody(data)
                        }
                        sendBody(Data())
                        
                    case .error(let error):
                        startResponse(ResponseStatus.internalServerError.description, [ ("Content-Type", "text/plain") ])
                        sendBody("An error occurred: \(error)".data(using: .utf8)!)
                        sendBody(Data())
                        
                    case .noRoute:
                        startResponse(ResponseStatus.notFound.description, [])
                        sendBody(Data())
                        
                    }
                }
            }
            
            
        }
        
        server = DefaultHTTPServer(eventLoop: loop, port: port ?? 0, app: app)
        
        try! server.start()
        
        loopThreadCondition = NSCondition()
        loopThread = Thread(target: self, selector: #selector(runEventLoop), object: nil)
        loopThread.start()
    }
    
    private func record(for path: String, queryString: String?, method: String, data: Data?, response: HTTPURLResponse) throws {
        guard let recordBaseURL = self.recordBaseURL else {
            return
        }
        
        let resource = mockPath(for: path, queryString: queryString, method: method, version: version)
        let recordURL = URL(string: ".\(resource)", relativeTo: recordBaseURL)!
        
        try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        
        if let data = data {
            try data.write(to: recordURL)
        }
        
        if let headersData = headerData(response: response) {
            let headersResource = mockPath(for: path, queryString: queryString, method: method, version: version, replaceExtension: "head")
            let headersURL = URL(string: ".\(headersResource)", relativeTo: recordBaseURL)!
            
            try headersData.write(to: headersURL)
        }
        
    }
    
    private func headerData(response: HTTPURLResponse) -> Data? {
        var string = "\(response.statusCode)\r\n"
        
        for header in response.allHeaderFields {
            let key = header.key as! String
            
            if Succulent.dontPassThroughHeaders[key.lowercased()] ?? false {
                continue
            }
            
            string += "\(key): \(header.value)\r\n"
        }
        return string.data(using: .utf8)
    }
    
    private func url(for path: String, queryString: String?, method: String, replaceExtension: String? = nil) -> URL? {
        var searchVersion = version
        while searchVersion >= 0 {
            let resource = mockPath(for: path, queryString: queryString, method: method, version: searchVersion, replaceExtension: replaceExtension)
            if let url = self.bundle.url(forResource: "Mock\(resource)", withExtension: nil) {
                return url
            }
            
            searchVersion -= 1
        }
        
        return nil
    }
    
    private func mockPath(for path: String, queryString: String?, method: String, version: Int, replaceExtension: String? = nil) -> String {
        let withoutExtension = (path as NSString).deletingPathExtension
        let ext = replaceExtension != nil ? replaceExtension! : (path as NSString).pathExtension
        let methodSuffix = (method == "GET") ? "" : "-\(method)"
        let querySuffix = (queryString == nil) ? "": "?\(queryString!)"
        
        return ("\(withoutExtension)-\(version)\(methodSuffix)" as NSString).appendingPathExtension(ext)!.appending(querySuffix)
    }
    
    private func contentType(for url: URL) -> String {
        var path = url.path
        if let r = path.range(of: "?", options: .backwards) {
            path = path.substring(to: r.lowerBound)
        }
        
        let ext = (path as NSString).pathExtension.lowercased()
        
        switch ext {
        case "json":
            return "text/json"
        case "txt":
            return "text/plain"
        default:
            return "application/x-octet-stream"
        }
    }
    
    public func stop() {
        server.stopAndWait()
        loopThreadCondition.lock()
        loop.stop()
        while loop.running {
            if !loopThreadCondition.wait(until: Date().addingTimeInterval(10)) {
                fatalError("Join eventLoopThread timeout")
            }
        }
    }
    
    @objc private func runEventLoop() {
        loop.runForever()
        loopThreadCondition.lock()
        loopThreadCondition.signal()
        loopThreadCondition.unlock()
    }
    
}
