import AVFAudio
import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

// MARK: - Core Audio device helpers

let kSystemObject = AudioObjectID(kAudioObjectSystemObject)

/// Every audio device Core Audio knows about.
func audioDeviceIDs() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(kSystemObject, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(kSystemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cfName: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfName) == noErr,
          let cfName else { return "(unknown)" }
    return cfName.takeRetainedValue() as String
}

/// Number of input channels across all of a device's input streams. The stream
/// configuration is a variable-length AudioBufferList, so allocate the size Core Audio
/// reports: the old single-AudioBufferList allocation overflowed the heap for devices
/// with more than one input stream.
func inputChannelCount(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, list) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
}

func transportType(_ id: AudioDeviceID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var type: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &type) == noErr ? type : 0
}

func isBluetooth(_ id: AudioDeviceID) -> Bool {
    let type = transportType(id)
    return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
}

func transportLabel(_ id: AudioDeviceID) -> String {
    switch transportType(id) {
    case kAudioDeviceTransportTypeBuiltIn: return "built-in"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "aggregate"
    case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
    case kAudioDeviceTransportTypeContinuityCaptureWired,
         kAudioDeviceTransportTypeContinuityCaptureWireless: return "iPhone"
    default: return "other"
    }
}

func defaultInputDevice() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(kSystemObject, &addr, 0, nil, &size, &id) == noErr,
          id != kAudioObjectUnknown else { return nil }
    return id
}

/// The Mac's own microphone, if it has one.
func builtInInputDevice() -> AudioDeviceID? {
    audioDeviceIDs().first {
        transportType($0) == kAudioDeviceTransportTypeBuiltIn && inputChannelCount($0) > 0
    }
}

/// Find an input device by name: an exact (case-insensitive) match first, then the
/// first name containing it, so a short name can't grab whichever device enumerates first.
func findInputDevice(named name: String) throws -> AudioDeviceID {
    let wanted = name.lowercased()
    let inputs = audioDeviceIDs().filter { inputChannelCount($0) > 0 }
    if let exact = inputs.first(where: { deviceName($0).lowercased() == wanted }) {
        return exact
    }
    if let partial = inputs.first(where: { deviceName($0).lowercased().contains(wanted) }) {
        return partial
    }
    throw MicCapture.MicError.deviceNotFound(name)
}

func deviceUID(_ id: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cfUID: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfUID) == noErr,
          let cfUID else { return nil }
    return cfUID.takeRetainedValue() as String
}

func nominalSampleRate(_ id: AudioDeviceID) -> Double {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr ? rate : 0
}

// MARK: - List apps

func listAudioApps() {
    print("Running apps:")
    for app in NSWorkspace.shared.runningApplications {
        if app.activationPolicy == .regular, let name = app.localizedName {
            print("  PID \(app.processIdentifier): \(name)")
        }
    }
}

// MARK: - List input devices

func listInputDevices() {
    let defaultDevice = defaultInputDevice()
    print("Input devices:")
    for id in audioDeviceIDs() where inputChannelCount(id) > 0 {
        var tags = [transportLabel(id)]
        if id == defaultDevice { tags.append("default") }
        print("  \(deviceName(id)) (\(tags.joined(separator: ", ")))")
    }
}
