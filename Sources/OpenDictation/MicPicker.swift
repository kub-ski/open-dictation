import AVFoundation
import CoreAudio
import IOKit

/// Which microphone a dictation records from.
///
/// macOS makes whatever just connected the default input, such as headphones that are busy with another
/// device. Those can deliver digital silence, and a silent take is a lost take. So the default is only used
/// when it is a local mic:
///
///   default (if local) → built-in (lid open) → USB/other wired → Bluetooth as the last resort.
///   The built-in mic is skipped while the lid is closed — macOS feeds it zeros then.
///   If a mic still delivers no sound, the recorder switches to the next one (see AudioRecorder).
enum MicPicker {

    struct Mic { let id: AudioDeviceID; let uid: String; let name: String; let transport: String }

    private static let bluetooth: Set<String> = ["blue", "blea"]           // last resort only
    private static let virtualish: Set<String> = ["virt", "grup", "fgrp", "airp"]   // not a room mic

    static func candidates(preferring hint: String? = nil) -> [Mic] {
        let mics = all()
        let lidClosed = clamshellClosed()
        let local = mics.filter { !bluetooth.contains($0.transport) && !virtualish.contains($0.transport)
                                  && !($0.transport == "bltn" && lidClosed) }
        let def = defaultInputID()
        var ordered = local.filter { $0.id == def }
                    + local.filter { $0.id != def && $0.transport == "bltn" }
                    + local.filter { $0.id != def && $0.transport != "bltn" }
                    + mics.filter { bluetooth.contains($0.transport) }
        // self-test only: start on a named mic even if it would be skipped (a dead one proves the watchdog)
        if let hint, let forced = mics.first(where: { $0.name.localizedCaseInsensitiveContains(hint) }) {
            ordered.removeAll { $0.id == forced.id }; ordered.insert(forced, at: 0)
        }
        return ordered
    }

    static func describe() -> String {
        let def = defaultInputID()
        return all().map { "\($0.name) [\($0.transport)\($0.id == def ? ", default" : "")]" }.joined(separator: ", ")
            + (clamshellClosed() ? " · lid closed" : " · lid open")
    }

    // MARK: CoreAudio

    static func all() -> [Mic] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0 else { return nil }
            return Mic(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName), transport: transport(id))
        }
    }

    static func defaultInputID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return "?" }
        return v.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0; var size = UInt32(4)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return String(bytes: [24, 16, 8, 0].map { UInt8((t >> $0) & 0xff) }, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }

    /// Lid closed = the built-in mic only delivers zeros.
    static func clamshellClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Bool) ?? false
    }
}
