import Foundation

let payload = Array(UInt8(0)..<32)
for chunk in 1...32 {
    var stream = InputFrames()
    var frames = [[UInt8]]()
    var complete = 0
    for start in stride(from: 0, to: payload.count, by: chunk) {
        let bytes = Data(payload[start..<min(start+chunk, payload.count)])
        complete += stream.receive(bytes) { frames.append(Array($0)); return true }!
    }
    precondition(complete == 4 && frames.allSatisfy { $0.count == 8 } && frames.flatMap { $0 } == payload)
}

var stream = InputFrames()
precondition(stream.receive(Data(repeating: 1, count: 7)) { _ in fatalError("partial frame") } == 0)
var calls = 0
let rejected = stream.receive(Data(repeating: 0, count: 17)) { _ in calls += 1; return false }
precondition(rejected == nil && calls == 1)
print("Swift receiver framing passed for 32 chunk sizes, a partial frame and a rejected frame.")

var events = [(MacEvent, InputFlags)]()
var bounds: CGRect? = CGRect(x: -1600, y: 100, width: 1600, height: 900)
let sink = InputSink(bounds: { bounds }, caps: false) { events.append(($0, $1)) }
func send(_ bytes: [UInt8]) {
    precondition(sink.apply((bytes + Array(repeating: 0, count: 8-bytes.count))[...]))
}
let topLeft = CGPoint(x: -1600, y: 100)
let bottomRight = CGPoint(x: -1, y: 999)
// v1 wire codes produced by the Windows MacBook-position layout.
let positions: [(UInt8, UInt16, InputFlags)] = [
    (231, 59, .control), (226, 58, .option), (224, 55, .command),
    (227, 54, .command), (230, 61, .option), (228, 62, .control)
]
for (wire, quartz, flag) in positions {
    send([4,wire,1])
    precondition(events.last!.0 == .keyboard(quartz, down: true, modifier: true, repeated: false))
    precondition(events.last!.1 == flag)
    send([4,wire,0])
    precondition(events.last!.0 == .keyboard(quartz, down: false, modifier: true, repeated: false))
    precondition(events.last!.1.isEmpty)
}
send([4,224,1]) // Command in the v1 protocol
send([4,6,1])
send([4,6,2])
precondition(events.last!.0 == .keyboard(8, down: true, modifier: false, repeated: true))
precondition(events.last!.1 == .command)
send([2,3,1,2])
precondition(events.last!.0 == .pointer(.down, button: 3, at: topLeft, clicks: 2))
send([1,0,0,0,255,255,255,255])
precondition(events.last!.0 == .pointer(.drag, button: 3, at: bottomRight, clicks: 2))
sink.release()
precondition(events.suffix(3).map { $0.0 } == [
    .pointer(.up, button: 3, at: bottomRight, clicks: 2),
    .keyboard(8, down: false, modifier: false, repeated: false),
    .keyboard(55, down: false, modifier: true, repeated: false)
])
precondition(events.last!.1.isEmpty)
let previous = events.count
sink.release()
send([4,6,0])
precondition(events.count == previous)
send([4,144,1])
precondition(events.suffix(4).map { $0.0 } == [
    .keyboard(59, down: true, modifier: true, repeated: false),
    .keyboard(49, down: true, modifier: false, repeated: false),
    .keyboard(49, down: false, modifier: false, repeated: false),
    .keyboard(59, down: false, modifier: true, repeated: false)
])
send([3,255,2])
precondition(events.last!.0 == .wheel(at: topLeft, vertical: 2, horizontal: -1))
bounds = CGRect(x: 10, y: 25, width: 1440, height: 900)
send([1,0,0,0,255,255,255,255])
precondition(events.last!.0 == .pointer(.move, button: 0, at: CGPoint(x: 1449, y: 924), clicks: 1))
bounds = nil
precondition(!sink.apply([0,0,0,0,0,0,0,0][...]))
print("Swift input mapping, double-click, drag, scroll, modifiers, repeat, input-source chord, display changes and disconnect release passed.")
