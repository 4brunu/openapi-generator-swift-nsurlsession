//
//  URLSessionImplementations.swift
//  OpenAPIClient
//
//  Created by Bruno Coelho on 23/11/2019.
//

import Foundation
#if !os(macOS)
import MobileCoreServices
#endif

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

internal class URLSessionRequestBuilder<T>: RequestBuilder<T> {
    
    let progress = Progress()
    
    private var observation: NSKeyValueObservation?
    
    deinit {
      observation?.invalidate()
    }
    
    let sessionDelegate = SessionDelegate()
    
    var taskDidReceiveChallenge: ((URLSession, URLSessionTask, URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))?
    var taskCompletionShouldRetry: ((Data?, URLResponse?, Error?, @escaping (Bool) -> Void) -> Void)?
    
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
        sessionDelegate.credential = credential
        sessionDelegate.taskDidReceiveChallenge = taskDidReceiveChallenge
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
    open func createURLRequest(urlSession: URLSession, method: HTTPMethod1, encoding: ParameterEncoding1, headers: [String:String]) throws -> URLRequest {
        
        guard let url = URL(string: URLString) else {
            throw DownloadException.requestMissingURL
        }
                
        var originalRequest = URLRequest(url: url)
        
        originalRequest.httpMethod = method.rawValue
        
        buildHeaders().forEach { key, value in
            originalRequest.setValue(value, forHTTPHeaderField: key)
        }
        
        headers.forEach { key, value in
            originalRequest.setValue(value, forHTTPHeaderField: key)
        }
        
        let modifiedRequest = try encoding.encode(originalRequest, with: parameters)
        
        return modifiedRequest
    }

    override func execute(_ completion: @escaping (Result<Response<T>, Error>) -> Void) {
        let urlSessionId:String = UUID().uuidString
        // Create a new manager for each request to customize its request header
        let urlSession = createURLSession()
        urlSessionStore[urlSessionId] = urlSession
        
        let parameters: [String: Any] = self.parameters ?? [:]
        
        let fileKeys = parameters.filter { $1 is NSURL }
            .map { $0.0 }
                
        let encoding: ParameterEncoding1
        if fileKeys.count > 0 {
            encoding = FileUploadEncoding(contentTypeForFormPart: contentTypeForFormPart(fileURL:))
        } else if isBody {
            encoding = JSONDataEncoding()
        } else {
            encoding = URLEncoding1()
        }
        
        guard let xMethod = HTTPMethod1(rawValue: method) else {
            fatalError("Unsuported Http method - \(method)")
        }
        
        let cleanupRequest = {
            urlSessionStore[urlSessionId] = nil
            self.observation?.invalidate()
        }
        
        do {
            let request = try createURLRequest(urlSession: urlSession, method: xMethod, encoding: encoding, headers: headers)
            
            let dataTask = urlSession.dataTask(with: request) { [weak self] data, response, error in
                                
                guard let self = self else { return }
                
                if let taskCompletionShouldRetry = self.taskCompletionShouldRetry {
                    
                    taskCompletionShouldRetry(data, response, error) { [weak self] shouldRetry in
                                       
                        guard let self = self else { return }
                        
                        if shouldRetry {
                            self.execute(completion)
                        } else {
                            
                            self.processRequestResponse(urlRequest: request, data: data, response: response, error: error, completion: completion)
                        }
                    }
                } else {
                    self.processRequestResponse(urlRequest: request, data: data, response: response, error: error, completion: completion)
                }
            }
            
            if #available(iOS 11.0, macOS 10.13, macCatalyst 13.0, tvOS 11.0, watchOS 4.0, *) {
                observation = dataTask.progress.observe(\.fractionCompleted) { newProgress, _ in
                    self.progress.totalUnitCount = newProgress.totalUnitCount
                    self.progress.completedUnitCount = newProgress.completedUnitCount
                }
                
                onProgressReady?(progress)
            }
            
            dataTask.resume()
                        
        } catch {
            cleanupRequest()
            completion(.failure(ErrorResponse.error(415, nil, error)))
        }

    }
    
    fileprivate func processRequestResponse(urlRequest: URLRequest, data: Data?, response: URLResponse?, error: Error?, completion: @escaping (Result<Response<T>, Error>) -> Void) {
        
        guard let httpResponse = response as? HTTPURLResponse else {
            completion(.failure(ErrorResponse.error(-2, nil, DecodableRequestBuilderError.nilHTTPResponse)))
            return
        }
        
        switch T.self {
        case is String.Type:
            
            if let error = error {
                completion(.failure(ErrorResponse.error(httpResponse.statusCode, data, error)))
                return
            }
            
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            
            completion(.success(Response<T>(response: httpResponse, body: body as? T)))
            
        case is URL.Type:
            do {
                
                guard error == nil else {
                    throw DownloadException.responseFailed
                }
                
                guard let data = data else {
                    throw DownloadException.responseDataMissing
                }
                
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
                
                completion(.success(Response(response: httpResponse, body: filePath as? T)))
                
            } catch let requestParserError as DownloadException {
                completion(.failure(ErrorResponse.error(400, data, requestParserError)))
            } catch let error {
                completion(.failure(ErrorResponse.error(400, data, error)))
            }
            
        case is Void.Type:
            
            if let error = error {
                completion(.failure(ErrorResponse.error(httpResponse.statusCode, data, error)))
                return
            }
            
            completion(.success(Response(response: httpResponse, body: nil)))
            
        default:
            
            if let error = error {
                completion(.failure(ErrorResponse.error(httpResponse.statusCode, data, error)))
                return
            }
            
            completion(.success(Response(response: httpResponse, body: data as? T)))
        }
    }

    open func buildHeaders() -> [String: String] {
        var httpHeaders = OpenAPIClientAPI.customHeaders
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

}

internal class URLSessionDecodableRequestBuilder<T:Decodable>: URLSessionRequestBuilder<T> {
    
    override func processRequestResponse(urlRequest: URLRequest, data: Data?, response: URLResponse?, error: Error?, completion: @escaping (Result<Response<T>, Error>) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completion(.failure(ErrorResponse.error(-2, nil, DecodableRequestBuilderError.nilHTTPResponse)))
            return
        }
        
        switch T.self {
        case is String.Type:
            
            if let error = error {
                completion(.failure(ErrorResponse.error(httpResponse.statusCode, data, error)))
                return
            }
            
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            
            completion(.success(Response<T>(response: httpResponse, body: body as? T)))
            
        case is Void.Type:
            
            if let error = error {
                completion(.failure(ErrorResponse.error(httpResponse.statusCode, data, error)))
                return
            }
            
            completion(.success(Response(response: httpResponse, body: nil)))
            
        case is Data.Type:
            
            if let error = error {
                completion(.failure(ErrorResponse.error(httpResponse.statusCode, data, error)))
                return
            }
            
            completion(.success(Response(response: httpResponse, body: data as? T)))
            
        default:
            
            if let error = error {
                completion(.failure(ErrorResponse.error(httpResponse.statusCode, data, error)))
                return
            }
            
            guard let data = data, !data.isEmpty else {
                completion(.failure(ErrorResponse.error(httpResponse.statusCode, nil, DecodableRequestBuilderError.emptyDataResponse)))
                return
            }
            
            let decodeResult = CodableHelper.decode(T.self, from: data)
            
            switch decodeResult {
            case let .success(responseObj):
                completion(.success(Response(response: httpResponse, body: responseObj)))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }
}

open class SessionDelegate: NSObject, URLSessionDelegate, URLSessionDataDelegate {
    
    var credential: URLCredential?
            
    var taskDidReceiveChallenge: ((URLSession, URLSessionTask, URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))?

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

        var disposition: URLSession.AuthChallengeDisposition = .performDefaultHandling

        var credential: URLCredential?

        if let taskDidReceiveChallenge = taskDidReceiveChallenge {
            (disposition, credential) = taskDidReceiveChallenge(session, task, challenge)
        } else {
            if challenge.previousFailureCount > 0 {
                disposition = .rejectProtectionSpace
            } else {
                credential = self.credential ?? session.configuration.urlCredentialStorage?.defaultCredential(for: challenge.protectionSpace)

                if credential != nil {
                    disposition = .useCredential
                }
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

class FileUploadEncoding: ParameterEncoding1 {
    
    let contentTypeForFormPart: (_ fileURL: URL) -> String?

    init(contentTypeForFormPart: @escaping (_ fileURL: URL) -> String?) {
        self.contentTypeForFormPart = contentTypeForFormPart
    }
    
    func encode(_ urlRequest: URLRequest, with parameters: [String : Any]?) throws -> URLRequest {
        
        var urlRequest = urlRequest
        
        for (k, v) in parameters ?? [:] {
            switch v {
            case let fileURL as URL:
                
                let fileData = try Data(contentsOf: fileURL)
                
                let mimetype = self.contentTypeForFormPart(fileURL) ?? mimeType(for: fileURL)
                
                urlRequest = configureFileUploadRequest(urlRequest: urlRequest, name: fileURL.lastPathComponent, data: fileData, mimeType: mimetype)
                
            case let string as String:
                
                if let data = string.data(using: .utf8) {
                    urlRequest = configureFileUploadRequest(urlRequest: urlRequest, name: k, data: data, mimeType: nil)
                }
                           
            case let number as NSNumber:
                
                if let data = number.stringValue.data(using: .utf8) {
                    urlRequest = configureFileUploadRequest(urlRequest: urlRequest, name: k, data: data, mimeType: nil)
                }
                
            default:
                fatalError("Unprocessable value \(v) with key \(k)")
            }
        }
        
        return urlRequest
    }
    
    private func configureFileUploadRequest(urlRequest: URLRequest, name: String, data: Data, mimeType: String?) -> URLRequest {

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

extension JSONDataEncoding: ParameterEncoding1 {}
