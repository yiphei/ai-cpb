import Foundation

struct CopyPayload {
    let imagePng: Data
    let capturedAt: Date
}

final class ContextStore {
    static let shared = ContextStore()

    private(set) var currentCopy: CopyPayload?

    func setCopy(_ payload: CopyPayload) {
        currentCopy = payload
        MenuBar.shared.setHasCopy(true)
    }

    func clear() {
        currentCopy = nil
        MenuBar.shared.setHasCopy(false)
    }
}
