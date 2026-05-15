import Foundation

struct CopyPayload {
    let imagePng: Data
    let capturedAt: Date
}

final class ContextStore {
    static let shared = ContextStore()
    static let maxCopies = 10

    private(set) var copies: [CopyPayload] = []

    func appendCopy(_ payload: CopyPayload) {
        copies.append(payload)
        if copies.count > Self.maxCopies {
            copies.removeFirst(copies.count - Self.maxCopies)
        }
        MenuBar.shared.setCopyCount(copies.count)
    }

    func clear() {
        copies.removeAll()
        MenuBar.shared.setCopyCount(0)
    }
}
