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

private struct SynchronizedDictionary<K: Hashable, V> {

     private var dictionary = [K: V]()
     private let queue = DispatchQueue(
         label: "SynchronizedDictionary",
         qos: DispatchQoS.userInitiated,
         attributes: [DispatchQueue.Attributes.concurrent],
         autoreleaseFrequency: DispatchQueue.AutoreleaseFrequency.inherit,
         target: nil
     )

     public subscript(key: K) -> V? {
         get {
             var value: V?

             queue.sync {
                 value = self.dictionary[key]
             }

             return value
         }
         set {
             queue.sync(flags: DispatchWorkItemFlags.barrier) {
                 self.dictionary[key] = newValue
             }
         }
     }
 }

// Store manager to retain its reference
private var urlSessionStore = SynchronizedDictionary<String, URLSession>()

open class URLSessionRequestBuilder<T>: RequestBuilder<T> {
    
    let urlSessionProgressTracker = URLSessionProgressTracker()
    
    required public init(method: String, URLString: String, parameters: [String : Any]?, isBody: Bool, headers: [String : String] = [:]) {
        super.init(method: method, URLString: URLString, parameters: parameters, isBody: isBody, headers: headers)
    }

    /**
     May be overridden by a subclass if you want to control the session
     configuration.
     */
    open func createURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = buildHeaders()
        return URLSession(configuration: configuration, delegate: urlSessionProgressTracker, delegateQueue: nil)
    }

    /**
     May be overridden by a subclass if you want to custom request constructor.
     */
    open func createURLRequest() -> URLRequest? {
        let encoding: ParameterEncoding1 = isBody ? JSONDataEncoding() : URLEncoding1()
        
        var originalRequest = URLRequest(url: URL(string: URLString)!)
        
        originalRequest.httpMethod = method
        
        buildHeaders().forEach { key, value in
            originalRequest.addValue(value, forHTTPHeaderField: key)
        }
        
        return try? encoding.encode(originalRequest, with: parameters)
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
    open func makeRequest(urlSession: URLSession, method: HTTPMethod1, encoding: ParameterEncoding1, headers: [String:String]) -> URLRequest? {

        var originalRequest = URLRequest(url: URL(string: URLString)!)
        
        originalRequest.httpMethod = method.rawValue
        
        buildHeaders().forEach { key, value in
            originalRequest.addValue(value, forHTTPHeaderField: key)
        }
        
        guard let modifiedRequest = try? encoding.encode(originalRequest, with: parameters) else {
            return nil
        }
        
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
            
            var originalRequest = URLRequest(url: URL(string: URLString)!)

            // https://stackoverflow.com/a/26163136/976628
            let boundary = "Boundary-\(UUID().uuidString)"
            originalRequest.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            var body = Data()
                        
            for (k, v) in self.parameters! {
                switch v {
                case let fileURL as URL:
                    if let mimeType = self.contentTypeForFormPart(fileURL: fileURL) {
                        body.append("--\(boundary)\r\n")
                        body.append("Content-Disposition: form-data; name=\"\(fileURL.lastPathComponent)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
                        body.append("Content-Type: \(mimeType)\r\n\r\n")

                        if let fileData = try? Data(contentsOf: fileURL) {
                            body.append(fileData)
                        }

//                        mpForm.append(fileURL, withName: k, fileName: fileURL.lastPathComponent, mimeType: mimeType)
                    }
                    else {
                        let mimetype = mimeType(for: fileURL)
                        
                        body.append("--\(boundary)\r\n")
                        body.append("Content-Disposition: form-data; name=\"\(k)\"; filename=\"\(k)\"\r\n")
                        body.append("Content-Type: \(mimetype)\r\n\r\n")

                        if let fileData = try? Data(contentsOf: fileURL) {
                            body.append(fileData)
                        }

                        
//                        mpForm.append(fileURL, withName: k)
                    }
                case let string as String:
                    body.append("--\(boundary)\r\n")
                    body.append("Content-Disposition: form-data; name=\"\(k)\"; filename=\"\(k)\"\r\n")
                    body.append(string)
                    
                    
//                    mpForm.append(string.data(using: String.Encoding.utf8)!, withName: k)
                case let number as NSNumber:
                    body.append("--\(boundary)\r\n")
                    body.append("Content-Disposition: form-data; name=\"\(k)\"; filename=\"\(k)\"\r\n")
                    body.append(number.stringValue)
                    
//                    mpForm.append(number.stringValue.data(using: String.Encoding.utf8)!, withName: k)
                default:
                    fatalError("Unprocessable value \(v) with key \(k)")
                }
            }

//            let fileUrl = URL(fileURLWithPath: filePath)
//            let fileName = fileUrl.lastPathComponent
//
//            let mimetype = mimeType(for: filePath)
//
//            body.append("--\(boundary)\r\n")
//            body.append("Content-Disposition: form-data; name=\"\(fileName)\"; filename=\"\(fileName)\"\r\n")
//            body.append("Content-Type: \(mimetype)\r\n\r\n")
//
//            if let fileData = try? Data(contentsOf: fileUrl) {
//                body.append(fileData)
//            }

            body.append("\r\n")

            body.append("--\(boundary)--\r\n")
                        
            var request = makeRequest(urlSession: urlSession, method: xMethod!, encoding: encoding, headers: headers)

            request?.httpBody = body
            
            onProgressReady?(urlSessionProgressTracker.progress)
            
            processRequest(urlSession: urlSession, request: request!, urlSessionId, completion)


            #warning("Done, but I'm not sure about the failure case")
//            manager.upload(multipartFormData: { mpForm in
//                for (k, v) in self.parameters! {
//                    switch v {
//                    case let fileURL as URL:
//                        if let mimeType = self.contentTypeForFormPart(fileURL: fileURL) {
//                            mpForm.append(fileURL, withName: k, fileName: fileURL.lastPathComponent, mimeType: mimeType)
//                        }
//                        else {
//                            mpForm.append(fileURL, withName: k)
//                        }
//                    case let string as String:
//                        mpForm.append(string.data(using: String.Encoding.utf8)!, withName: k)
//                    case let number as NSNumber:
//                        mpForm.append(number.stringValue.data(using: String.Encoding.utf8)!, withName: k)
//                    default:
//                        fatalError("Unprocessable value \(v) with key \(k)")
//                    }
//                }
//                }, to: URLString, method: xMethod!, headers: nil, encodingCompletion: { encodingResult in
//                switch encodingResult {
//                case .success(let upload, _, _):
//                    if let onProgressReady = self.onProgressReady {
//                        onProgressReady(upload.uploadProgress)
//                    }
//                    self.processRequest(request: upload, managerId, completion)
//                case .failure(let encodingError):
//                    completion(nil, ErrorResponse.error(415, nil, encodingError))
//                }
//            })
        } else {
            let request = makeRequest(urlSession: urlSession, method: xMethod!, encoding: encoding, headers: headers)
            
            onProgressReady?(urlSessionProgressTracker.progress)
            
            processRequest(urlSession: urlSession, request: request!, urlSessionId, completion)
        }

    }

    fileprivate func processRequest(urlSession: URLSession, request: URLRequest, _ urlSessionId: String, _ completion: @escaping (_ response: Response<T>?, _ error: Error?) -> Void) {
        if let credential = self.credential {
            #warning("TODO")
            //            request.authenticate(usingCredential: credential)
        }
        
        let cleanupRequest = {
            urlSessionStore[urlSessionId] = nil
        }
        
        #warning("HERE!")
        //        let validatedRequest = request.validate()
        
        urlSession.dataTask(with: request) { data, response, error in
            
            cleanupRequest()
            
            switch T.self {
            case is String.Type:
                
                if let error = error {
                    completion(
                        nil,
                        ErrorResponse.error(response?.statusCode ?? 500, data, error)
                    )
                    return
                }
                
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                
                completion(
                    Response<T>(
                        response: response as! HTTPURLResponse,
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
                    
                    guard let response = response as? HTTPURLResponse else {
                        #warning("HERE! Wrong exception")
                        throw DownloadException.requestMissing
                    }
                    
//                    guard let request = request else {
//                        throw DownloadException.requestMissing
//                    }
                    
                    let fileManager = FileManager.default
                    let urlRequest = try request.asURLRequest()
                    let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let requestURL = try self.getURL(from: urlRequest)
                    
                    var requestPath = try self.getPath(from: requestURL)
                    
                    if let headerFileName = self.getFileName(fromContentDisposition: response.allHeaderFields["Content-Disposition"] as? String) {
                        requestPath = requestPath.appending("/\(headerFileName)")
                    }
                    
                    let filePath = documentsDirectory.appendingPathComponent(requestPath)
                    let directoryPath = filePath.deletingLastPathComponent().path
                    
                    try fileManager.createDirectory(atPath: directoryPath, withIntermediateDirectories: true, attributes: nil)
                    try data.write(to: filePath, options: .atomic)
                    
                    completion(
                        Response(
                            response: response,
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
                    ErrorResponse.error(response?.statusCode ?? 500, data, error)
                )
                return
            }
            
            completion(
                Response(
                    response: response as! HTTPURLResponse,
                    body: nil
                ),
                nil
            )
            
            default:
            
            if let error = error {
                completion(
                    nil,
                    ErrorResponse.error(response?.statusCode ?? 500, data, error)
                )
                return
            }
            
            completion(
                Response(
                    response: response as! HTTPURLResponse,
                    body: data as? T
                ),
                nil
            )
        }
        }.resume()
        
    }

    open func buildHeaders() -> [String: String] {
        #warning("HERE!")
//        var httpHeaders = SessionManager.defaultHTTPHeaders
        var httpHeaders: [String: String] = [:]
        for (key, value) in self.headers {
            httpHeaders[key] = value
        }
        return httpHeaders
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

open class URLSessionProgressTracker: NSObject, URLSessionDelegate, URLSessionDataDelegate {
    
    let progress = Progress()

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        progress.totalUnitCount = response.expectedContentLength
        completionHandler(.allow)
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        progress.completedUnitCount = progress.completedUnitCount + Int64(data.count)
    }
    
}


extension Data {
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

extension URLResponse {
    var statusCode: Int? {
        guard let httpResponse = self as? HTTPURLResponse else {
            return nil
        }
        return httpResponse.statusCode
    }
}

fileprivate enum DownloadException : Error {
    case responseDataMissing
    case responseFailed
    case requestMissing
    case requestMissingPath
    case requestMissingURL
}

public enum URLSessionDecodableRequestBuilderError: Error {
    case emptyDataResponse
    case nilHTTPResponse
    case jsonDecoding(DecodingError)
    case generalError(Error)
}

#warning("HERE!")
open class URLSessionDecodableRequestBuilder<T:Decodable>: URLSessionRequestBuilder<T> {

    override fileprivate func processRequest(urlSession: URLSession, request: URLRequest, _ urlSessionId: String, _ completion: @escaping (_ response: Response<T>?, _ error: Error?) -> Void) {
        if let credential = self.credential {
            #warning("TODO")
            //            request.authenticate(usingCredential: credential)
        }
        
        let cleanupRequest = {
            urlSessionStore[urlSessionId] = nil
        }
        
        #warning("HERE!")
        //        let validatedRequest = request.validate()
        
        urlSession.dataTask(with: request) { data, response, error in
            
            cleanupRequest()
            
            switch T.self {
            case is String.Type:
                
                if let error = error {
                    completion(
                        nil,
                        ErrorResponse.error(response?.statusCode ?? 500, data, error)
                    )
                    return
                }
                
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                
                completion(
                    Response<T>(
                        response: response as! HTTPURLResponse,
                        body: body as? T
                    ),
                    nil
                )
                
            case is Void.Type:
                
                if let error = error {
                    completion(
                        nil,
                        ErrorResponse.error(response?.statusCode ?? 500, data, error)
                    )
                    return
                }
                
                completion(
                    Response(
                        response: response as! HTTPURLResponse,
                        body: nil
                    ),
                    nil
                )
                
            case is Data.Type:
                
                if let error = error {
                    completion(
                        nil,
                        ErrorResponse.error(response?.statusCode ?? 500, data, error)
                    )
                    return
                }
                
                completion(
                    Response(
                        response: response as! HTTPURLResponse,
                        body: data as! T
                    ),
                    nil
                )
                
            default:
                
                guard error != nil else {
                    completion(nil, ErrorResponse.error(response?.statusCode ?? 500, data, error!))
                    return
                }

                guard let data = data, !data.isEmpty else {
                    completion(nil, ErrorResponse.error(-1, nil, URLSessionDecodableRequestBuilderError.emptyDataResponse))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(nil, ErrorResponse.error(-2, nil, URLSessionDecodableRequestBuilderError.nilHTTPResponse))
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
            #warning("HERE")
            throw DownloadException.requestMissing
        }

        if var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false), !parameters.isEmpty {
            urlComponents.queryItems = APIHelper.mapValuesToQueryItems(parameters)
            urlRequest.url = urlComponents.url
        }
        
        return urlRequest
    }
}
