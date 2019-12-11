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
        return URLSession(configuration: configuration)
    }

    /**
     May be overridden by a subclass if you want to custom request constructor.
     */
    open func createURLRequest() -> URLRequest? {
        let encoding: ParameterEncoding = isBody ? JSONDataEncoding() : URLEncoding()
        
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
    open func makeRequest(urlSession: URLSession, method: HTTPMethod, encoding: ParameterEncoding, headers: [String:String]) -> URLRequest? {

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

        let encoding:ParameterEncoding = isBody ? JSONDataEncoding() : URLEncoding()

        let xMethod = HTTPMethod(rawValue: method)
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
                        
            let request = makeRequest(urlSession: urlSession, method: xMethod!, encoding: encoding, headers: headers)

            request?.httpBody = body
            
            #warning("TODO")
            //            if let onProgressReady = self.onProgressReady {
            //                if #available(OSX 10.13, *) {
            //                    onProgressReady(request!.progress)
            //                }
            //            }
            
            processRequest(request: request!, urlSessionId, completion)


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
            #warning("TODO")
            //            if let onProgressReady = self.onProgressReady {
            //                if #available(OSX 10.13, *) {
            //                    onProgressReady(request!.progress)
            //                }
            //            }
            processRequest(request: request!, urlSessionId, completion)
        }

    }

    fileprivate func processRequest(request: URLRequest, _ urlSessionId: String, _ completion: @escaping (_ response: Response<T>?, _ error: Error?) -> Void) {
        if let credential = self.credential {
            #warning("TODO")
            //            request.authenticate(usingCredential: credential)
        }
        
        let cleanupRequest = {
            urlSessionStore[urlSessionId] = nil
        }
        
        #warning("HERE!")
        //        let validatedRequest = request.validate()
        
        createURLSession().dataTask(with: request) { data, response, error in
            
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

    override fileprivate func processRequest(request: URLRequest, _ urlSessionId: String, _ completion: @escaping (_ response: Response<T>?, _ error: Error?) -> Void) {
        if let credential = self.credential {
            #warning("TODO")
            //            request.authenticate(usingCredential: credential)
        }
        
        let cleanupRequest = {
            urlSessionStore[urlSessionId] = nil
        }
        
        #warning("HERE!")
        //        let validatedRequest = request.validate()
        
        createURLSession().dataTask(with: request) { data, response, error in
            
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

public protocol ParameterEncoding {
    /// Creates a URL request by encoding parameters and applying them onto an existing request.
    ///
    /// - parameter urlRequest: The request to have parameters applied.
    /// - parameter parameters: The parameters to apply.
    ///
    /// - throws: An `AFError.parameterEncodingFailed` error if encoding fails.
    ///
    /// - returns: The encoded request.
    func encode(_ urlRequest: URLRequest, with parameters: [String: Any]?) throws -> URLRequest
}

/// Creates a url-encoded query string to be set as or appended to any existing URL query string or set as the HTTP
/// body of the URL request. Whether the query string is set or appended to any existing URL query string or set as
/// the HTTP body depends on the destination of the encoding.
///
/// The `Content-Type` HTTP header field of an encoded request with HTTP body is set to
/// `application/x-www-form-urlencoded; charset=utf-8`.
///
/// There is no published specification for how to encode collection types. By default the convention of appending
/// `[]` to the key for array values (`foo[]=1&foo[]=2`), and appending the key surrounded by square brackets for
/// nested dictionary values (`foo[bar]=baz`) is used. Optionally, `ArrayEncoding` can be used to omit the
/// square brackets appended to array keys.
///
/// `BoolEncoding` can be used to configure how boolean values are encoded. The default behavior is to encode
/// `true` as 1 and `false` as 0.
public struct URLEncoding: ParameterEncoding {

    // MARK: Helper Types

    /// Defines whether the url-encoded query string is applied to the existing query string or HTTP body of the
    /// resulting URL request.
    ///
    /// - methodDependent: Applies encoded query string result to existing query string for `GET`, `HEAD` and `DELETE`
    ///                    requests and sets as the HTTP body for requests with any other HTTP method.
    /// - queryString:     Sets or appends encoded query string result to existing query string.
    /// - httpBody:        Sets encoded query string result as the HTTP body of the URL request.
    public enum Destination {
        case methodDependent, queryString, httpBody
    }

    /// Configures how `Array` parameters are encoded.
    ///
    /// - brackets:        An empty set of square brackets is appended to the key for every value.
    ///                    This is the default behavior.
    /// - noBrackets:      No brackets are appended. The key is encoded as is.
    public enum ArrayEncoding {
        case brackets, noBrackets

        func encode(key: String) -> String {
            switch self {
            case .brackets:
                return "\(key)[]"
            case .noBrackets:
                return key
            }
        }
    }

    /// Configures how `Bool` parameters are encoded.
    ///
    /// - numeric:         Encode `true` as `1` and `false` as `0`. This is the default behavior.
    /// - literal:         Encode `true` and `false` as string literals.
    public enum BoolEncoding {
        case numeric, literal

        func encode(value: Bool) -> String {
            switch self {
            case .numeric:
                return value ? "1" : "0"
            case .literal:
                return value ? "true" : "false"
            }
        }
    }

    // MARK: Properties

    /// Returns a default `URLEncoding` instance.
    public static var `default`: URLEncoding { return URLEncoding() }

    /// Returns a `URLEncoding` instance with a `.methodDependent` destination.
    public static var methodDependent: URLEncoding { return URLEncoding() }

    /// Returns a `URLEncoding` instance with a `.queryString` destination.
    public static var queryString: URLEncoding { return URLEncoding(destination: .queryString) }

    /// Returns a `URLEncoding` instance with an `.httpBody` destination.
    public static var httpBody: URLEncoding { return URLEncoding(destination: .httpBody) }

    /// The destination defining where the encoded query string is to be applied to the URL request.
    public let destination: Destination

    /// The encoding to use for `Array` parameters.
    public let arrayEncoding: ArrayEncoding

    /// The encoding to use for `Bool` parameters.
    public let boolEncoding: BoolEncoding

    // MARK: Initialization

    /// Creates a `URLEncoding` instance using the specified destination.
    ///
    /// - parameter destination: The destination defining where the encoded query string is to be applied.
    /// - parameter arrayEncoding: The encoding to use for `Array` parameters.
    /// - parameter boolEncoding: The encoding to use for `Bool` parameters.
    ///
    /// - returns: The new `URLEncoding` instance.
    public init(destination: Destination = .methodDependent, arrayEncoding: ArrayEncoding = .brackets, boolEncoding: BoolEncoding = .numeric) {
        self.destination = destination
        self.arrayEncoding = arrayEncoding
        self.boolEncoding = boolEncoding
    }

    // MARK: Encoding

    /// Creates a URL request by encoding parameters and applying them onto an existing request.
    ///
    /// - parameter urlRequest: The request to have parameters applied.
    /// - parameter parameters: The parameters to apply.
    ///
    /// - throws: An `Error` if the encoding process encounters an error.
    ///
    /// - returns: The encoded request.
    public func encode(_ urlRequest: URLRequestConvertible, with parameters: [String: Any]?) throws -> URLRequest {
        var urlRequest = try urlRequest.asURLRequest()

        guard let parameters = parameters else { return urlRequest }

        if let method = HTTPMethod(rawValue: urlRequest.httpMethod ?? "GET"), encodesParametersInURL(with: method) {
            guard let url = urlRequest.url else {
                throw AFError.parameterEncodingFailed(reason: .missingURL)
            }

            if var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false), !parameters.isEmpty {
                let percentEncodedQuery = (urlComponents.percentEncodedQuery.map { $0 + "&" } ?? "") + query(parameters)
                urlComponents.percentEncodedQuery = percentEncodedQuery
                urlRequest.url = urlComponents.url
            }
        } else {
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }

            urlRequest.httpBody = query(parameters).data(using: .utf8, allowLossyConversion: false)
        }

        return urlRequest
    }

    /// Creates percent-escaped, URL encoded query string components from the given key-value pair using recursion.
    ///
    /// - parameter key:   The key of the query component.
    /// - parameter value: The value of the query component.
    ///
    /// - returns: The percent-escaped, URL encoded query string components.
    public func queryComponents(fromKey key: String, value: Any) -> [(String, String)] {
        var components: [(String, String)] = []

        if let dictionary = value as? [String: Any] {
            for (nestedKey, value) in dictionary {
                components += queryComponents(fromKey: "\(key)[\(nestedKey)]", value: value)
            }
        } else if let array = value as? [Any] {
            for value in array {
                components += queryComponents(fromKey: arrayEncoding.encode(key: key), value: value)
            }
        } else if let value = value as? NSNumber {
            #warning("HERE!")
//            if value.isBool {
//                components.append((escape(key), escape(boolEncoding.encode(value: value.boolValue))))
//            } else {
//                components.append((escape(key), escape("\(value)")))
//            }
        } else if let bool = value as? Bool {
            components.append((escape(key), escape(boolEncoding.encode(value: bool))))
        } else {
            components.append((escape(key), escape("\(value)")))
        }

        return components
    }

    /// Returns a percent-escaped string following RFC 3986 for a query string key or value.
    ///
    /// RFC 3986 states that the following characters are "reserved" characters.
    ///
    /// - General Delimiters: ":", "#", "[", "]", "@", "?", "/"
    /// - Sub-Delimiters: "!", "$", "&", "'", "(", ")", "*", "+", ",", ";", "="
    ///
    /// In RFC 3986 - Section 3.4, it states that the "?" and "/" characters should not be escaped to allow
    /// query strings to include a URL. Therefore, all "reserved" characters with the exception of "?" and "/"
    /// should be percent-escaped in the query string.
    ///
    /// - parameter string: The string to be percent-escaped.
    ///
    /// - returns: The percent-escaped string.
    public func escape(_ string: String) -> String {
        let generalDelimitersToEncode = ":#[]@" // does not include "?" or "/" due to RFC 3986 - Section 3.4
        let subDelimitersToEncode = "!$&'()*+,;="

        var allowedCharacterSet = CharacterSet.urlQueryAllowed
        allowedCharacterSet.remove(charactersIn: "\(generalDelimitersToEncode)\(subDelimitersToEncode)")

        var escaped = ""

        //==========================================================================================================
        //
        //  Batching is required for escaping due to an internal bug in iOS 8.1 and 8.2. Encoding more than a few
        //  hundred Chinese characters causes various malloc error crashes. To avoid this issue until iOS 8 is no
        //  longer supported, batching MUST be used for encoding. This introduces roughly a 20% overhead. For more
        //  info, please refer to:
        //
        //      - https://github.com/Alamofire/Alamofire/issues/206
        //
        //==========================================================================================================

        if #available(iOS 8.3, *) {
            escaped = string.addingPercentEncoding(withAllowedCharacters: allowedCharacterSet) ?? string
        } else {
            let batchSize = 50
            var index = string.startIndex

            while index != string.endIndex {
                let startIndex = index
                let endIndex = string.index(index, offsetBy: batchSize, limitedBy: string.endIndex) ?? string.endIndex
                let range = startIndex..<endIndex

                let substring = string[range]

                escaped += substring.addingPercentEncoding(withAllowedCharacters: allowedCharacterSet) ?? String(substring)

                index = endIndex
            }
        }

        return escaped
    }

    private func query(_ parameters: [String: Any]) -> String {
        var components: [(String, String)] = []

        for key in parameters.keys.sorted(by: <) {
            let value = parameters[key]!
            components += queryComponents(fromKey: key, value: value)
        }
        return components.map { "\($0)=\($1)" }.joined(separator: "&")
    }

    private func encodesParametersInURL(with method: HTTPMethod) -> Bool {
        switch destination {
        case .queryString:
            return true
        case .httpBody:
            return false
        default:
            break
        }

        switch method {
        case .get, .head, .delete:
            return true
        default:
            return false
        }
    }
}

public enum HTTPMethod: String {
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
