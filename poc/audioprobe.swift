// audioprobe — reports which processes are currently producing audio output,
// using ONLY public CoreAudio APIs (macOS 14.2+). No TCC permission required.
// This is the "is QQMusic actually playing?" detector for the wake flow and test harness.
// Usage: audioprobe [pid]        (with pid: exit 0 if that pid is outputting audio, 1 otherwise)
//        audioprobe              (no arg: list all processes with their output state)
import Foundation
import CoreAudio
import AppKit

func getPID() -> pid_t { getpid() }

func audioObjectGetPropertyDataSize(_ id: AudioObjectID, addr: AudioObjectPropertyAddress) -> UInt32 {
    var size: UInt32 = 0
    var a = addr
    let st = AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
    return st == noErr ? size : 0
}

func audioObjectGetPropertyData<T>(_ id: AudioObjectID, addr: AudioObjectPropertyAddress, type: T.Type) -> T? {
    var a = addr
    var value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
    defer { value.deallocate() }
    var size = UInt32(MemoryLayout<T>.size)
    let st = AudioObjectGetPropertyData(id, &a, 0, nil, &size, value)
    guard st == noErr else { return nil }
    return value.load(as: T.self)
}

var processListAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

let hw = AudioObjectID(kAudioObjectSystemObject)
let size = audioObjectGetPropertyDataSize(hw, addr: processListAddr)
let count = Int(size) / MemoryLayout<AudioObjectID>.size
var ids = [AudioObjectID](repeating: 0, count: count)
var listSize = size
var a = processListAddr
let st = AudioObjectGetPropertyData(hw, &a, 0, nil, &listSize, &ids)
guard st == noErr else {
    print("ERR: ProcessObjectList failed \(st)")
    exit(3)
}

let pidFilter: pid_t? = CommandLine.arguments.count > 1 ? pid_t(CommandLine.arguments[1]) ?? nil : nil
var foundRunning = false
for id in ids {
    func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    let pid = audioObjectGetPropertyData(id, addr: addr(kAudioProcessPropertyPID), type: pid_t.self) ?? -1
    let runningOut = audioObjectGetPropertyData(id, addr: addr(kAudioProcessPropertyIsRunningOutput), type: UInt32.self) ?? 0
    let runningIn = audioObjectGetPropertyData(id, addr: addr(kAudioProcessPropertyIsRunningInput), type: UInt32.self) ?? 0
    if let f = pidFilter {
        if pid == f {
            print("pid \(pid): outputRunning=\(runningOut) inputRunning=\(runningIn)")
            foundRunning = runningOut != 0
        }
    } else {
        let name = (NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?")
        print("audioObject \(id) pid \(pid) (\(name)): out=\(runningOut) in=\(runningIn)")
    }
}
exit(pidFilter != nil ? (foundRunning ? 0 : 1) : 0)
