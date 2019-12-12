//
//  URLSessionImplementations.swift
//  OpenAPIClient
//
//  Created by Bruno Coelho on 23/11/2019.
//

import Foundation

class URLSessionRequestBuilderFactory: RequestBuilderFactory {
    func getNonDecodableBuilder<T>() -> RequestBuilder<T>.Type {
        return URLSessionRequestBuilder<T>.self
    }

    func getBuilder<T:Decodable>() -> RequestBuilder<T>.Type {
        return URLSessionDecodableRequestBuilder<T>.self
    }
}

// Store manager to retain its reference
private var urlSessionStore = SynchronizedDictionary<String, URLSession>()

open class URLSessionRequestBuilder<T>: RequestBuilder<T> {
    
    let sessionDelegate = SessionDelegate()
    
    required public init(method: String, URLString: String, parameters: [String : Any]?, isBody: Bool, headers: [String : String] = [:]) {
        super.init(method: method, URLString: URLString, parameters: parameters, isBody: isBody, headers: headers)
    }
    
    open override func addCredential() -> Self {
        _ = super.addCredential()
        sessionDelegate.credential = self.credential
        return self
    }

    /**
     May be overridden by a subclass if you want to control the session
     configuration.
     */
    open func createURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = buildHeaders()
        return URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
    }

    /**
     May be overridden by a subclass if you want to control the Content-Type
     that is given to an uploaded form part.

     Return nil to use the default behavior (inferring the Content-Type from
     the file extension).  Return the desired Content-Type otherwise.
     */
    open func contentTypeForFormPart(fileURL: URL) -> String? {
        return nil
    }

    /**
     May be overridden by a subclass if you want to control the request
     configuration (e.g. to override the cache policy).
     */
    open func makeRequest(urlSession: URLSession, method: HTTPMethod1, encoding: ParameterEncoding1, headers: [String:String]) throws -> URLRequest {

        var originalRequest = URLRequest(url: URL(string: URLString)!)
        
        originalRequest.httpMethod = method.rawValue
        
        buildHeaders().forEach { key, value in
            originalRequest.addValue(value, forHTTPHeaderField: key)
        }
        
        let modifiedRequest = try encoding.encode(originalRequest, with: parameters)
        
        return modifiedRequest
    }

    override open func execute(_ completion: @escaping (_ response: Response<T>?, _ error: Error?) -> Void) {
        let urlSessionId:String = UUID().uuidString
        // Create a new manager for each request to customize its request header
        let urlSession = createURLSession()
        urlSessionStore[urlSessionId] = urlSession
                
        let encoding:ParameterEncoding1 = isBody ? JSONDataEncoding() : URLEncoding1()

        let xMethod = HTTPMethod1(rawValue: method)
        let fileKeys = parameters == nil ? [] : parameters!.filter { $1 is NSURL }
                                                           .map { $0.0 }

        if fileKeys.count > 0 {
            
            do {
                
                var request = try makeRequest(urlSession: urlSession, method: xMethod!, encoding: encoding, headers: headers)
                            
                for (k, v) in self.parameters! {
                    switch v {
                    case let fileURL as URL:
                        
                        let fileData = try Data(contentsOf: fileURL)
                        
                        if let mimeType = self.contentTypeForFormPart(fileURL: fileURL) {
                            
                            request = configureFileUploadRequest(urlRequest: request, name: fileURL.lastPathComponent, data: fileData, mimeType: mimeType)
                            
                        }
                        else {
                            let mimetype = mimeType(for: fileURL)
                            
                            request = configureFileUploadRequest(urlRequest: request, name: fileURL.lastPathComponent, data: fileData, mimeType: mimetype)
                            
                        }
                    case let string as String:
                        
                        if let data = string.data(using: .utf8) {
                            request = configureFileUploadRequest(urlRequest: request, name: k, data: data, mimeType: nil)
                        }
                                   
                    case let number as NSNumber:
                        
                        if let data = number.stringValue.data(using: .utf8) {
                            request = configureFileUploadRequest(urlRequest: request, name: k, data: data, mimeType: nil)
                        }
                        
                    default:
                        fatalError("Unprocessable value \(v) with key \(k)")
                    }
                }
                
                onProgressReady?(sessionDelegate.progress)
                
                processRequest(urlSession: urlSession, urlRequest: request, urlSessionId, completion)
                
            } catch {
                completion(nil, ErrorResponse.error(415, nil, error))
            }
            
        } else {
            
            do {
                let request = try makeRequest(urlSession: urlSession, method: xMethod!, encoding: encoding, headers: headers)
                
                onProgressReady?(sessionDelegate.progress)
                
                processRequest(urlSession: urlSession, urlRequest: request, urlSessionId, completion)
                
            } catch {
                completion(nil, ErrorResponse.error(415, nil, error))
            }
        }

    }

    fileprivate func processRequest(urlSession: URLSession, urlRequest: URLRequest, _ urlSessionId: String, _ completion: @escaping (_ response: Response<T>?, _ error: Error?) -> Void) {
        
        let cleanupRequest = {
            urlSessionStore[urlSessionId] = nil
        }
        
        urlSession.dataTask(with: urlRequest) { data, response, error in
            
            cleanupRequest()
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(nil, ErrorResponse.error(-2, nil, DecodableRequestBuilderError.nilHTTPResponse))
                return
            }
            
            switch T.self {
            case is String.Type:
                
                if let error = error {
                    completion(
                        nil,
                        ErrorResponse.error(httpResponse.statusCode, data, error)
                    )
                    return
                }
                
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                
                completion(
                    Response<T>(
                        response: httpResponse,
                        body: body as? T
                    ),
                    nil
                )
                
            case is URL.Type:
                do {
                    
                    guard error == nil else {
                        throw DownloadException.responseFailed
                    }
                    
                    guard let data = data else {
                        throw DownloadException.responseDataMissing
                    }
                    
//                    guard let request = request else {
//                        throw DownloadException.requestMissing
//                    }
                    
                    let fileManager = FileManager.default
                    let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let requestURL = try self.getURL(from: urlRequest)
                    
                    var requestPath = try self.getPath(from: requestURL)
                    
                    if let headerFileName = self.getFileName(fromContentDisposition: httpResponse.allHeaderFields["Content-Disposition"] as? String) {
                        requestPath = requestPath.appending("/\(headerFileName)")
                    }
                    
                    let filePath = documentsDirectory.appendingPathComponent(requestPath)
                    let directoryPath = filePath.deletingLastPathComponent().path
                    
                    try fileManager.createDirectory(atPath: directoryPath, withIntermediateDirectories: true, attributes: nil)
                    try data.write(to: filePath, options: .atomic)
                    
                    completion(
                        Response(
                            response: httpResponse,
                            body: (filePath as! T)
                        ),
                        nil
                    )
                    
                } catch let requestParserError as DownloadException {
                    completion(nil, ErrorResponse.error(400, data, requestParserError))
                } catch let error {
                    completion(nil, ErrorResponse.error(400, data, error))
                }
            
            case is Void.Type:
            
            if let error = error {
                completion(
                    nil,
                    ErrorResponse.error(httpResponse.statusCode, data, error)
                )
                return
            }
            
            completion(
                Response(
                    response: httpResponse,
                    body: nil
                ),
                nil
            )
            
            default:
            
            if let error = error {
                completion(
                    nil,
                    ErrorResponse.error(httpResponse.statusCode, data, error)
                )
                return
            }
            
            completion(
                Response(
                    response: httpResponse,
                    body: data as? T
                ),
                nil
            )
        }
        }.resume()
        
    }

    open func buildHeaders() -> [String: String] {
        #warning("Should we define some default http headers?")
//        var httpHeaders = SessionManager.defaultHTTPHeaders
        var httpHeaders: [String: String] = [:]
        for (key, value) in self.headers {
            httpHeaders[key] = value
        }
        return httpHeaders
    }
    
    fileprivate func configureFileUploadRequest(urlRequest: URLRequest, name: String, data: Data, mimeType: String?) -> URLRequest {

        var urlRequest = urlRequest

        var body = urlRequest.httpBody ?? Data()
        
        // https://stackoverflow.com/a/26163136/976628
        let boundary = "Boundary-\(UUID().uuidString)"
        urlRequest.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(name)\"\r\n")
        
        if let mimeType = mimeType {
            body.append("Content-Type: \(mimeType)\r\n\r\n")
        }
        
        body.append(data)

        body.append("\r\n")

        body.append("--\(boundary)--\r\n")

        urlRequest.httpBody = body
        
        return urlRequest

    }

    fileprivate func getFileName(fromContentDisposition contentDisposition : String?) -> String? {

        guard let contentDisposition = contentDisposition else {
            return nil
        }

        let items = contentDisposition.components(separatedBy: ";")

        var filename : String? = nil

        for contentItem in items {

            let filenameKey = "filename="
            guard let range = contentItem.range(of: filenameKey) else {
                break
            }

            filename = contentItem
            return filename?
                .replacingCharacters(in: range, with:"")
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return filename

    }

    fileprivate func getPath(from url : URL) throws -> String {

        guard var path = URLComponents(url: url, resolvingAgainstBaseURL: true)?.path else {
            throw DownloadException.requestMissingPath
        }

        if path.hasPrefix("/") {
            path.remove(at: path.startIndex)
        }

        return path

    }

    fileprivate func getURL(from urlRequest : URLRequest) throws -> URL {

        guard let url = urlRequest.url else {
            throw DownloadException.requestMissingURL
        }

        return url
    }
    
    func mimeType(for url: URL) -> String {
        let pathExtension = url.pathExtension

        if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, pathExtension as NSString, nil)?.takeRetainedValue() {
            if let mimetype = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType)?.takeRetainedValue() {
                return mimetype as String
            }
        }
        return "application/octet-stream"
    }

}

open class URLSessionDecodableRequestBuilder<T:Decodable>: URLSessionRequestBuilder<T> {

    override fileprivate func processRequest(urlSession: URLSession, urlRequest request: URLRequest, _ urlSessionId: String, _ completion: @escaping (_ response: Response<T>?, _ error: Error?) -> Void) {
        
        let cleanupRequest = {
            urlSessionStore[urlSessionId] = nil
        }
                
        urlSession.dataTask(with: request) { data, response, error in
            
            cleanupRequest()
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(nil, ErrorResponse.error(-2, nil, DecodableRequestBuilderError.nilHTTPResponse))
                return
            }
            
            switch T.self {
            case is String.Type:
                
                if let error = error {
                    completion(
                        nil,
                        ErrorResponse.error(httpResponse.statusCode, data, error)
                    )
                    return
                }
                
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                
                completion(
                    Response<T>(
                        response: httpResponse,
                        body: body as? T
                    ),
                    nil
                )
                
            case is Void.Type:
                
                if let error = error {
                    completion(
                        nil,
                        ErrorResponse.error(httpResponse.statusCode, data, error)
                    )
                    return
                }
                
                completion(
                    Response(
                        response: httpResponse,
                        body: nil
                    ),
                    nil
                )
                
            case is Data.Type:
                
                if let error = error {
                    completion(
                        nil,
                        ErrorResponse.error(httpResponse.statusCode, data, error)
                    )
                    return
                }
                
                completion(
                    Response(
                        response: httpResponse,
                        body: data as? T
                    ),
                    nil
                )
                
            default:
                
                guard error != nil else {
                    completion(nil, ErrorResponse.error(httpResponse.statusCode, data, error!))
                    return
                }

                guard let data = data, !data.isEmpty else {
                    completion(nil, ErrorResponse.error(-1, nil, DecodableRequestBuilderError.emptyDataResponse))
                    return
                }

                var responseObj: Response<T>? = nil

                let decodeResult: (decodableObj: T?, error: Error?) = CodableHelper.decode(T.self, from: data)
                if decodeResult.error == nil {
                    responseObj = Response(response: httpResponse, body: decodeResult.decodableObj)
                }

                completion(responseObj, decodeResult.error)
                
            }
        }.resume()
        
    }

}

open class SessionDelegate: NSObject, URLSessionDelegate, URLSessionDataDelegate {
    
    var credential: URLCredential?
    
    let progress = Progress()

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        progress.totalUnitCount = response.expectedContentLength
        completionHandler(.allow)
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        progress.completedUnitCount = progress.completedUnitCount + Int64(data.count)
    }
    
//    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
//
//    }
    
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

        var disposition: URLSession.AuthChallengeDisposition = .performDefaultHandling
        
        var credential: URLCredential?

        if challenge.previousFailureCount > 0 {
            disposition = .rejectProtectionSpace
        } else {
            credential = self.credential ?? session.configuration.urlCredentialStorage?.defaultCredential(for: challenge.protectionSpace)

            if credential != nil {
                disposition = .useCredential
            }
        }
        
        completionHandler(disposition, credential)
        
    }
    
}


public enum HTTPMethod1: String {
    case options = "OPTIONS"
    case get     = "GET"
    case head    = "HEAD"
    case post    = "POST"
    case put     = "PUT"
    case patch   = "PATCH"
    case delete  = "DELETE"
    case trace   = "TRACE"
    case connect = "CONNECT"
}

public protocol ParameterEncoding1 {
    func encode(_ urlRequest: URLRequest, with parameters: [String: Any]?) throws -> URLRequest
}

class URLEncoding1: ParameterEncoding1 {
    func encode(_ urlRequest: URLRequest, with parameters: [String : Any]?) throws -> URLRequest {
        
        var urlRequest = urlRequest
        
        guard let parameters = parameters else { return urlRequest }
        
        guard let url = urlRequest.url else {
            throw DownloadException.requestMissingURL
        }

        if var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false), !parameters.isEmpty {
            urlComponents.queryItems = APIHelper.mapValuesToQueryItems(parameters)
            urlRequest.url = urlComponents.url
        }
        
        return urlRequest
    }
}

fileprivate extension Data {
    /// Append string to NSMutableData
    ///
    /// Rather than littering my code with calls to `dataUsingEncoding` to convert strings to NSData, and then add that data to the NSMutableData, this wraps it in a nice convenient little extension to NSMutableData. This converts using UTF-8.
    ///
    /// - parameter string:       The string to be added to the `NSMutableData`.

    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}


