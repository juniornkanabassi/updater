import Foundation

extension Task where Failure == Error {
  /// A cache owns its shared fetch; cancelling one reader must release that
  /// reader promptly without cancelling the fetch for other readers.
  func valueUnlessCancelled() async throws -> Success {
    try Task<Never, Never>.checkCancellation()
    let stream = AsyncThrowingStream<Success, Error> { continuation in
      let waiter = Task<Void, Never> {
        do {
          continuation.yield(try await self.value)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in waiter.cancel() }
    }
    var iterator = stream.makeAsyncIterator()
    guard let value = try await iterator.next() else { throw _Concurrency.CancellationError() }
    try Task<Never, Never>.checkCancellation()
    return value
  }
}
