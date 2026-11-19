import Foundation

// TLS delivers a byte stream. Apply complete events in order and keep at most
// seven bytes between callbacks. A partial event never reaches Core Graphics.
struct InputFrames {
    private var pending = [UInt8]()
    mutating func receive(_ data: Data, apply: (ArraySlice<UInt8>) -> Bool) -> Int? {
        pending.append(contentsOf: data)
        let complete = pending.count - pending.count % 8
        for offset in stride(from: 0, to: complete, by: 8) {
            if !apply(pending[offset..<offset+8]) { return nil }
        }
        pending.removeFirst(complete)
        return complete / 8
    }
}
