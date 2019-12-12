//
//  SynchronizedDictionary.swift
//  
//
//  Created by Bruno Coelho on 12/12/2019.
//

import Foundation

internal struct SynchronizedDictionary<K: Hashable, V> {

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
