//
//  MainActorAsyncStreamRegistry.swift
//  Latest
//
//  Created by Max Langer on 20.01.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import Foundation

/// Produces bounded async state feeds and automatically removes terminated consumers.
@MainActor
final class MainActorAsyncStreamRegistry<Value: Sendable> {
  private var continuations = [UUID: AsyncStream<Value>.Continuation]()

  func stream(initialValue: Value) -> AsyncStream<Value> {
    let identifier = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: Value.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    continuations[identifier] = continuation
    continuation.yield(initialValue)
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.continuations.removeValue(forKey: identifier)
      }
    }
    return stream
  }

  func yield(_ value: Value) {
    for continuation in continuations.values {
      continuation.yield(value)
    }
  }
}
