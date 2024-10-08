//
//  OKModelInfoRequestData.swift
//
//
//  Created by Kevin Hermawan on 10/11/23.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A structure that encapsulates the data necessary for requesting information about a specific model from the Ollama API.
public struct OKModelInfoRequestData: Encodable {
    /// A string representing the identifier of the model for which information is requested.
    public let name: String
    
    public init(name: String) {
        self.name = name
    }
}
