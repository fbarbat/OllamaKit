//
//  OKHTTPClient.swift
//
//
//  Created by Kevin Hermawan on 08/06/24.
//

import OpenCombine
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

internal struct OKHTTPClient {
    private let decoder: JSONDecoder = .default
    static let shared = OKHTTPClient()
}

internal extension OKHTTPClient {
    func send(request: URLRequest) async throws -> Void {
        let (_, response) = try await URLSession.shared.data(for: request)
        
        try validate(response: response)
    }
    
    func send<T: Decodable>(request: URLRequest, with responseType: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)
        
        return try decoder.decode(T.self, from: data)
    }
    
    func stream<T: Decodable>(request: URLRequest, with responseType: T.Type) -> AsyncThrowingStream<T, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await request.bytes()
                    try validate(response: response)
                    
                    var buffer = Data()
                    
                    for try await byte in bytes {
                        buffer.append(byte)
                        
                        while let chunk = self.extractNextJSON(from: &buffer) {
                            do {
                                let decodedObject = try self.decoder.decode(T.self, from: chunk)
                                continuation.yield(decodedObject)
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

extension Publisher where Output == URLSession.CustomDataTaskPublisher.Output {
    func decode<Item, Coder>(type: Item.Type, decoder: Coder) -> Publishers.TryMap<Self, Item> where Item: Decodable, Coder: TopLevelDecoder, Coder.Input == Data {
        return tryMap { try decoder.decode(type, from: $0.data) }
    }
}

extension JSONDecoder: @retroactive TopLevelDecoder {}

internal extension OKHTTPClient {
    func send<T: Decodable>(request: URLRequest, with responseType: T.Type) -> AnyPublisher<T, Error> {
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response in
                try self.validate(response: response)
                
                return data
            }
            .decode(type: T.self, decoder: decoder)
            .eraseToAnyPublisher()
    }
    
    func send(request: URLRequest) -> AnyPublisher<Void, Error> {
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { _, response in
                try self.validate(response: response)
                
                return ()
            }
            .eraseToAnyPublisher()
    }
    
    func stream<T: Decodable>(request: URLRequest, with responseType: T.Type) -> AnyPublisher<T, Error> {
        let delegate = StreamingDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        
        let task = session.dataTask(with: request)
        task.resume()
        
        var buffer = Data()
        
        return delegate.publisher()
            .tryMap { newData -> [T] in
                buffer.append(newData)
                var decodedObjects: [T] = []
                
                while let chunk = self.extractNextJSON(from: &buffer) {
                    let decodedObject = try self.decoder.decode(T.self, from: chunk)
                    decodedObjects.append(decodedObject)
                }
                
                return decodedObjects
            }
            .flatMap { decodedObjects -> AnyPublisher<T, Error> in
                Publishers.Sequence(sequence: decodedObjects)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}

private extension OKHTTPClient {
    func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
    
    func extractNextJSON(from buffer: inout Data) -> Data? {
        var isEscaped = false
        var isWithinString = false
        var nestingDepth = 0
        var objectStartIndex = buffer.startIndex
        
        for (index, byte) in buffer.enumerated() {
            let character = Character(UnicodeScalar(byte))
            
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                isWithinString.toggle()
            } else if !isWithinString {
                switch character {
                case "{":
                    nestingDepth += 1
                    if nestingDepth == 1 {
                        objectStartIndex = index
                    }
                case "}":
                    nestingDepth -= 1
                    if nestingDepth == 0 {
                        let range = objectStartIndex..<buffer.index(after: index)
                        let jsonObject = buffer.subdata(in: range)
                        buffer.removeSubrange(range)
                        
                        return jsonObject
                    }
                default:
                    break
                }
            }
        }
        
        return nil
    }
}


final class StreamDelegate: NSObject {
    private var dataContinuation: AsyncThrowingStream<UInt8, Error>.Continuation?
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    
    func startRequest(with url: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            self.dataContinuation = continuation
        }
        
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLResponse, Error>) in
            self.responseContinuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: url)
            task.resume()
        } 
        
        return (stream, response)
    }
}

extension StreamDelegate: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        responseContinuation?.resume(returning: response)
        responseContinuation = nil
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for byte in data {
            dataContinuation?.yield(byte)
        }
    }
    
    enum StreamDelegateError: Error {
        case taskCompletedBeforeResponse
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if let responseContinuation {
                responseContinuation.resume(throwing: error)
            } else {
                dataContinuation?.finish(throwing: error)
            }
        } else {
            responseContinuation?.resume(throwing: StreamDelegateError.taskCompletedBeforeResponse)
            dataContinuation?.finish()
        }
        
        responseContinuation = nil
        dataContinuation = nil
    }
}

extension URLRequest {
    public func bytes() async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
        // This is retained until the task finishes
        let streamDelegate = StreamDelegate()
        return try await streamDelegate.startRequest(with: self)
    }
}

extension URLSession {
    struct CustomDataTaskPublisher: Publisher {
        typealias Output = (data: Data, response: URLResponse)
        typealias Failure = URLError

        let session: URLSession
        let request: URLRequest

        func receive<S>(subscriber: S) where S : Subscriber, URLError == S.Failure, (data: Data, response: URLResponse) == S.Input {
            let subscription = DataTaskSubscription(subscriber: subscriber, session: session, request: request)
            subscriber.receive(subscription: subscription)
        }

        private final class DataTaskSubscription<S: Subscriber>: Subscription where S.Input == (data: Data, response: URLResponse), S.Failure == URLError {
            private var subscriber: S?
            private var task: URLSessionDataTask?

            init(subscriber: S, session: URLSession, request: URLRequest) {
                self.subscriber = subscriber
                self.task = session.dataTask(with: request) { data, response, error in
                    if let error = error as? URLError {
                        subscriber.receive(completion: .failure(error))
                    } else if let data = data, let response = response {
                        _ = subscriber.receive((data: data, response: response))
                        subscriber.receive(completion: .finished)
                    }
                }
            }

            func request(_ demand: Subscribers.Demand) {
                task?.resume()
            }

            func cancel() {
                task?.cancel()
                task = nil
                subscriber = nil
            }
        }
    }

    /// Returns a publisher that wraps a URL session data task for a given URL.
    ///
    /// The publisher publishes data when the task completes, or terminates if the task fails with an error.
    /// - Parameter url: The URL for which to create a data task.
    /// - Returns: A publisher that wraps a data task for the URL.
    func dataTaskPublisher(for request: URLRequest) -> CustomDataTaskPublisher {
        return CustomDataTaskPublisher(session: self, request: request)
    }
}

