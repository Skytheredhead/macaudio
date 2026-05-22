import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let channelCount: Int

    var label: String {
        "\(name) (\(id))"
    }
}

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let channelCount: Int

    var label: String {
        "\(name) (\(id))"
    }
}

enum AudioDeviceCatalog {
    private static let preferredVirtualDeviceTokens = [
        "BlackHole",
        "Background Music",
        "Teams Audio",
        "Voicemod",
        "Parrot"
    ]

    static func listInputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard deviceHasInput(id), !isMacAudioVirtualMic(id) else { return nil }
            return AudioInputDevice(
                id: id,
                name: nameForDevice(id),
                channelCount: deviceChannelCount(id, scope: kAudioObjectPropertyScopeInput)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func listOutputDevices() -> [AudioOutputDevice] {
        allDeviceIDs().compactMap { id in
            guard deviceHasOutput(id) else { return nil }
            return AudioOutputDevice(
                id: id,
                name: nameForDevice(id),
                channelCount: deviceChannelCount(id, scope: kAudioObjectPropertyScopeOutput)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        return status == noErr ? deviceID : 0
    }

    static func preferredOutputDeviceID() -> AudioDeviceID {
        let outputs = listOutputDevices()

        if let virtualDevice = outputs.first(where: { isLikelyVirtualOutput($0.name) }) {
            return virtualDevice.id
        }

        return defaultOutputDeviceID()
    }

    static func isLikelyVirtualOutput(_ name: String) -> Bool {
        preferredVirtualDeviceTokens.contains { token in
            name.localizedCaseInsensitiveContains(token)
        }
    }

    @discardableResult
    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> OSStatus {
        var mutableID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableID
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let statusSize = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard statusSize == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        let statusData = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids)
        guard statusData == noErr else { return [] }
        return ids
    }

    static func deviceName(_ deviceID: AudioDeviceID) -> String {
        nameForDevice(deviceID)
    }

    static func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        return status == noErr ? deviceID : 0
    }

    static func preferredInputDeviceID() -> AudioDeviceID {
        let defaultID = defaultInputDeviceID()
        if defaultID != 0, deviceHasInput(defaultID), !isMacAudioVirtualMic(defaultID) {
            return defaultID
        }

        return listInputDevices().first?.id ?? 0
    }

    static func isMacAudioVirtualMic(_ deviceID: AudioDeviceID) -> Bool {
        deviceUID(deviceID) == "com.skylarenns.macaudio.virtualmic.device"
            || nameForDevice(deviceID) == "Virtual Mic"
    }

    static func inputChannelCount(deviceID: AudioDeviceID) -> Int {
        deviceChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
    }

    static func outputChannelCount(deviceID: AudioDeviceID) -> Int {
        deviceChannelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
    }

    @discardableResult
    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> OSStatus {
        var mutableID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableID
        )
    }

    @discardableResult
    static func setNominalSampleRate(deviceID: AudioDeviceID, sampleRate: Double) -> OSStatus {
        var mutableSampleRate = sampleRate
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Double>.size),
            &mutableSampleRate
        )
    }

    static func nominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Double = 0
        var dataSize = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)
        guard status == noErr, sampleRate > 0 else { return nil }
        return sampleRate
    }

    @discardableResult
    static func setBufferFrameSize(deviceID: AudioDeviceID, frameSize: UInt32) -> OSStatus {
        var mutableFrameSize = frameSize
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableFrameSize
        )
    }

    private static func deviceHasInput(_ deviceID: AudioDeviceID) -> Bool {
        deviceChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput) > 0
    }

    private static func deviceHasOutput(_ deviceID: AudioDeviceID) -> Bool {
        deviceChannelCount(deviceID, scope: kAudioObjectPropertyScopeOutput) > 0
    }

    private static func deviceChannelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let statusSize = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard statusSize == noErr, dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer)
        guard status == noErr else { return 0 }

        let audioBufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.reduce(0) { total, buffer in
            total + Int(buffer.mNumberChannels)
        }
    }

    private static func nameForDevice(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var unmanagedName: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &unmanagedName)
        guard status == noErr, let unmanagedName else {
            return "Input \(deviceID)"
        }
        return unmanagedName.takeUnretainedValue() as String
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var unmanagedUID: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &unmanagedUID)
        guard status == noErr, let unmanagedUID else {
            return nil
        }
        return unmanagedUID.takeUnretainedValue() as String
    }
}
