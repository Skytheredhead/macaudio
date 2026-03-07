import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import QuartzCore

final class AudioEngineController: ObservableObject {
    private static let noInputFramesWarning = "No input frames from the selected microphone."
    private static let recoveringInputWarning = "Recovering microphone input..."

    @Published var isRunning = false
    @Published var availableInputDevices: [AudioInputDevice] = []
    @Published var availableOutputDevices: [AudioOutputDevice] = []
    @Published var selectedInputDeviceID: AudioDeviceID = 0
    @Published var selectedMonitorDeviceID: AudioDeviceID = 0
    @Published var selectedSampleRate: SampleRateOption = .auto
    @Published var selectedBufferSize: BufferSizeOption = .auto

    @Published var monitorEnabled = false
    @Published var monitorLevel: Float = 0.25
    @Published var latencyQuality: Float = 0.55

    @Published var inputPeak: Float = 0
    @Published var inputRMS: Float = 0
    @Published var outputPeak: Float = 0
    @Published var outputRMS: Float = 0
    @Published var gainReductionDB: Float = 0
    @Published var clippedSamples: UInt32 = 0

    @Published var xrunsOverruns: UInt32 = 0
    @Published var xrunsUnderruns: UInt32 = 0
    @Published var warningMessage: String?
    @Published var routeStatus = "No output"

    private var engine = AVAudioEngine()
    private let maxFramesPerBuffer = 2048
    private let monitorRingName = "/macaudio-mon"
    private let hardwareObserverQueue = DispatchQueue(label: "com.skylarenns.macaudio.hardware", qos: .utility)

    private var dspChain: OpaquePointer?
    private var inputUnit: AudioUnit?
    private var monitorWriter: OpaquePointer?
    private var monitorReader: OpaquePointer?

    private var processScratch: UnsafeMutablePointer<Float>
    private var monitorScratch: UnsafeMutablePointer<Float>
    private var inputBufferListPointer: UnsafeMutablePointer<AudioBufferList>?
    private var inputSampleRate: Double = 48_000

    private var meterTimer: DispatchSourceTimer?
    private var monitorSourceNode: AVAudioSourceNode?
    private var lastInputTapTime: TimeInterval = 0
    private var inputWatchdogGraceUntil: TimeInterval = 0
    private var hardwareListenerBlock: AudioObjectPropertyListenerBlock?
    private var pendingHardwareRefresh: DispatchWorkItem?

    private var currentSettings = VoicePreset.cleanVoice.settings
    private var xrunAutoFallbackTriggered = false
    private var originalDefaultOutputDeviceID: AudioDeviceID?
    private var inputRecoveryAttempts = 0

    init() {
        processScratch = .allocate(capacity: maxFramesPerBuffer)
        monitorScratch = .allocate(capacity: maxFramesPerBuffer)
        startObservingHardwareChanges()
        refreshInputDevices()
        applyLatencyQuality(latencyQuality)
    }

    deinit {
        stopObservingHardwareChanges()
        stop()
        processScratch.deallocate()
        monitorScratch.deallocate()
    }

    func refreshInputDevices() {
        availableInputDevices = AudioDeviceCatalog.listInputDevices()
        availableOutputDevices = AudioDeviceCatalog.listOutputDevices()
        let fallback = AudioDeviceCatalog.defaultInputDeviceID()
        if selectedInputDeviceID == 0 {
            selectedInputDeviceID = fallback
        }
        if !availableInputDevices.contains(where: { $0.id == selectedInputDeviceID }) {
            selectedInputDeviceID = fallback
        }

        let outputFallback = AudioDeviceCatalog.preferredOutputDeviceID()
        if selectedMonitorDeviceID == 0 {
            selectedMonitorDeviceID = outputFallback
        }
        if !availableOutputDevices.contains(where: { $0.id == selectedMonitorDeviceID }) {
            selectedMonitorDeviceID = outputFallback
        }

        routeStatus = selectedMonitorDeviceID == 0 ? "No output" : AudioDeviceCatalog.deviceName(selectedMonitorDeviceID)
    }

    func setPreset(_ preset: VoicePreset) {
        currentSettings = preset.settings
        applyLatencyQuality(latencyQuality)
        pushParametersToDSP()
    }

    func updateSettings(_ settings: VoiceProcessingSettings) {
        currentSettings = settings
        pushParametersToDSP()
    }

    func start() {
        startEngine(resetInputRecovery: true)
    }

    private func startEngine(resetInputRecovery: Bool) {
        guard !isRunning else { return }

        refreshInputDevices()
        warningMessage = nil
        xrunAutoFallbackTriggered = false
        if resetInputRecovery {
            inputRecoveryAttempts = 0
        }

        let inputDevice = selectedInputDeviceID == 0 ? AudioDeviceCatalog.defaultInputDeviceID() : selectedInputDeviceID
        guard inputDevice != 0 else {
            warningMessage = "No input device found. Connect a microphone and retry."
            return
        }

        applyMonitorRoutingIfNeeded()
        _ = AudioDeviceCatalog.setDefaultInputDevice(inputDevice)

        if let sampleRate = selectedSampleRate.sampleRate {
            _ = AudioDeviceCatalog.setNominalSampleRate(deviceID: inputDevice, sampleRate: sampleRate)
        }

        if let frameSize = selectedBufferSize.frames {
            _ = AudioDeviceCatalog.setBufferFrameSize(deviceID: inputDevice, frameSize: frameSize)
        }

        engine = AVAudioEngine()
        lastInputTapTime = CACurrentMediaTime()
        inputWatchdogGraceUntil = lastInputTapTime + 3.0

        do {
            let sampleRate = try setupInputUnit(deviceID: inputDevice)
            inputSampleRate = sampleRate
            setupRingBuffers(sampleRate: sampleRate)

            dspChain = dsp_chain_create(sampleRate, 1)
            pushParametersToDSP()

            setupMonitorNode(sampleRate: sampleRate)

            try startInputUnit()
            try engine.start()
            isRunning = true
            startMeterTimer()
        } catch {
            warningMessage = "Audio engine start failed: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        meterTimer?.cancel()
        meterTimer = nil

        if let monitorNode = monitorSourceNode {
            engine.disconnectNodeInput(monitorNode)
            engine.detach(monitorNode)
            monitorSourceNode = nil
        }

        engine.stop()
        stopInputUnit()

        if let chain = dspChain {
            dsp_chain_destroy(chain)
            dspChain = nil
        }

        closeRing(&monitorWriter)
        closeRing(&monitorReader)
        restoreDefaultOutputDeviceIfNeeded()

        isRunning = false
    }

    func applyLatencyQuality(_ value: Float) {
        latencyQuality = min(max(value, 0), 1)

        if latencyQuality < 0.34 {
            selectedBufferSize = .f256
            currentSettings.denoiseStrength = max(currentSettings.denoiseStrength, 0.55)
        } else if latencyQuality < 0.67 {
            selectedBufferSize = .f128
            currentSettings.denoiseStrength = max(min(currentSettings.denoiseStrength, 0.45), 0.30)
        } else {
            selectedBufferSize = .f64
            currentSettings.denoiseStrength = min(currentSettings.denoiseStrength, 0.22)
        }

        pushParametersToDSP()
    }

    func updateMonitorDevice(_ deviceID: AudioDeviceID) {
        selectedMonitorDeviceID = deviceID
        routeStatus = selectedMonitorDeviceID == 0 ? "No output" : AudioDeviceCatalog.deviceName(selectedMonitorDeviceID)
        if isRunning {
            restartForRouteChange()
        } else {
            applyMonitorRoutingIfNeeded()
        }
    }

    func updateInputDevice(_ deviceID: AudioDeviceID) {
        selectedInputDeviceID = deviceID
        guard isRunning else { return }
        restartForConfigurationChange()
    }

    func updateIOConfiguration(sampleRate: SampleRateOption, bufferSize: BufferSizeOption) {
        selectedSampleRate = sampleRate
        selectedBufferSize = bufferSize
        guard isRunning else { return }
        restartForConfigurationChange()
    }

    func setMonitorEnabled(_ enabled: Bool) {
        monitorEnabled = enabled
        guard isRunning else { return }

        if enabled {
            applyMonitorRoutingIfNeeded()
        } else {
            restoreDefaultOutputDeviceIfNeeded()
        }
    }

    private func setupRingBuffers(sampleRate: Double) {
        _ = monitorRingName.withCString { vm_ring_unlink($0) }

        closeRing(&monitorWriter)
        closeRing(&monitorReader)

        var monitorWriter: OpaquePointer?
        let monitorWriterResult = monitorRingName.withCString {
            vm_ring_create_writer($0, 8192, 1, &monitorWriter)
        }
        guard monitorWriterResult == 0, let monitorWriter else {
            warningMessage = "Output route buffer failed (\(monitorWriterResult))."
            return
        }
        vm_ring_set_sample_rate(monitorWriter, UInt32(sampleRate))
        self.monitorWriter = monitorWriter

        var monitorReader: OpaquePointer?
        let monitorReaderResult = monitorRingName.withCString {
            vm_ring_open_reader($0, &monitorReader)
        }
        if monitorReaderResult == 0, let monitorReader {
            self.monitorReader = monitorReader
        }
    }

    private func handleInputFrames(frameCount: Int) {
        guard frameCount > 0 && frameCount <= maxFramesPerBuffer else { return }
        lastInputTapTime = CACurrentMediaTime()

        if let chain = dspChain {
            dsp_chain_process_mono(chain, processScratch, UInt32(frameCount))
        }

        if let monitorWriter {
            _ = vm_ring_write(monitorWriter, processScratch, UInt32(frameCount))
        }
    }

    private func setupInputUnit(deviceID: AudioDeviceID) throws -> Double {
        stopInputUnit()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioEngineError.halComponentUnavailable
        }

        var maybeUnit: AudioUnit?
        guard AudioComponentInstanceNew(component, &maybeUnit) == noErr, let unit = maybeUnit else {
            throw AudioEngineError.halComponentUnavailable
        }
        inputUnit = unit

        var enableInput: UInt32 = 1
        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        ) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not enable microphone input.")
        }

        var disableOutput: UInt32 = 0
        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        ) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not disable HAL output bus.")
        }

        var mutableDeviceID = deviceID
        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not bind the selected microphone.")
        }

        let sampleRate = selectedSampleRate.sampleRate ?? AudioDeviceCatalog.nominalSampleRate(deviceID: deviceID) ?? 48_000
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        guard AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not configure microphone stream format.")
        }

        var callback = AURenderCallbackStruct(
            inputProc: AudioEngineController.inputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not install microphone callback.")
        }

        var maxFrames = UInt32(maxFramesPerBuffer)
        _ = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            UInt32(MemoryLayout<UInt32>.size)
        )

        allocateInputBufferList()

        guard AudioUnitInitialize(unit) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not initialize microphone capture.")
        }

        return sampleRate
    }

    private func startInputUnit() throws {
        guard let inputUnit else {
            throw AudioEngineError.halConfigurationFailed("Microphone capture is not configured.")
        }
        guard AudioOutputUnitStart(inputUnit) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not start microphone capture.")
        }
    }

    private func stopInputUnit() {
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
            self.inputUnit = nil
        }

        if let inputBufferListPointer {
            inputBufferListPointer.deallocate()
            self.inputBufferListPointer = nil
        }
    }

    private func allocateInputBufferList() {
        inputBufferListPointer?.deallocate()
        let inputBufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        inputBufferListPointer.initialize(to: AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(maxFramesPerBuffer * MemoryLayout<Float>.size),
                mData: processScratch
            )
        ))
        self.inputBufferListPointer = inputBufferListPointer
    }

    private static let inputRenderCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
        let controller = Unmanaged<AudioEngineController>.fromOpaque(inRefCon).takeUnretainedValue()
        return controller.renderInput(ioActionFlags: ioActionFlags, timeStamp: inTimeStamp, frameCount: inNumberFrames)
    }

    private func renderInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard
            let inputUnit,
            let inputBufferListPointer,
            frameCount > 0,
            Int(frameCount) <= maxFramesPerBuffer
        else {
            return noErr
        }

        let buffers = UnsafeMutableAudioBufferListPointer(inputBufferListPointer)
        buffers[0].mData = UnsafeMutableRawPointer(processScratch)
        buffers[0].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)

        let status = AudioUnitRender(inputUnit, ioActionFlags, timeStamp, 1, frameCount, inputBufferListPointer)
        guard status == noErr else {
            return status
        }

        handleInputFrames(frameCount: Int(frameCount))
        return noErr
    }

    private func setupMonitorNode(sampleRate: Double) {
        guard monitorSourceNode == nil else { return }

        guard let monitorFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            return
        }

        let source = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let frames = Int(frameCount)
            guard frames <= self.maxFramesPerBuffer else { return noErr }

            var readFrames = 0
            if let reader = self.monitorReader {
                readFrames = Int(vm_ring_read(reader, self.monitorScratch, UInt32(frames)))
            }

            let gain: Float = self.monitorLevel
            let limitedGain = min(max(gain, 0), 2)
            let safeCeiling: Float = 0.98

            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for bufferIndex in 0..<buffers.count {
                guard let mData = buffers[bufferIndex].mData else { continue }
                let out = mData.assumingMemoryBound(to: Float.self)

                for frame in 0..<readFrames {
                    var sample = self.monitorScratch[frame] * limitedGain
                    sample = max(min(sample, safeCeiling), -safeCeiling)
                    out[frame] = sample
                }

                if readFrames < frames {
                    out.advanced(by: readFrames).initialize(repeating: 0, count: frames - readFrames)
                }
            }
            return noErr
        }

        monitorSourceNode = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: monitorFormat)
    }

    private func applyMonitorRoutingIfNeeded() {
        guard selectedMonitorDeviceID != 0 else { return }

        if originalDefaultOutputDeviceID == nil {
            originalDefaultOutputDeviceID = AudioDeviceCatalog.defaultOutputDeviceID()
        }

        let currentDefault = AudioDeviceCatalog.defaultOutputDeviceID()
        if currentDefault == selectedMonitorDeviceID {
            routeStatus = AudioDeviceCatalog.deviceName(selectedMonitorDeviceID)
            return
        }

        let status = AudioDeviceCatalog.setDefaultOutputDevice(selectedMonitorDeviceID)
        if status != noErr {
            warningMessage = "Could not switch monitor output device."
            return
        }
        routeStatus = AudioDeviceCatalog.deviceName(selectedMonitorDeviceID)
    }

    private func restoreDefaultOutputDeviceIfNeeded() {
        guard let originalDefaultOutputDeviceID else { return }
        _ = AudioDeviceCatalog.setDefaultOutputDevice(originalDefaultOutputDeviceID)
        self.originalDefaultOutputDeviceID = nil
    }

    private func pushParametersToDSP() {
        guard let chain = dspChain else { return }

        var params = DSPChainParameters()
        params.inputGainDB = currentSettings.inputGainDB
        params.hpfHz = currentSettings.hpfHz
        params.lowGainDB = currentSettings.lowGainDB
        params.midGainDB = currentSettings.midGainDB
        params.highGainDB = currentSettings.highGainDB
        params.compressorThresholdDB = currentSettings.compressorThresholdDB
        params.compressorRatio = currentSettings.compressorRatio
        params.compressorAttackMs = currentSettings.compressorAttackMs
        params.compressorReleaseMs = currentSettings.compressorReleaseMs
        params.makeupGainDB = currentSettings.makeupGainDB
        params.limiterCeilingDB = currentSettings.limiterCeilingDB
        params.outputGainDB = currentSettings.outputGainDB
        params.denoiseEnabled = currentSettings.denoiseEnabled
        params.denoiseStrength = currentSettings.denoiseStrength
        params.gateEnabled = currentSettings.gateEnabled
        params.gateThresholdDB = currentSettings.gateThresholdDB
        params.deEsserEnabled = currentSettings.deEsserEnabled
        params.deEsserAmount = currentSettings.deEsserAmount

        dsp_chain_set_parameters(chain, params)
    }

    private func startMeterTimer() {
        meterTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(90), leeway: .milliseconds(15))
        timer.setEventHandler { [weak self] in
            self?.pollRealtimeStats()
        }
        meterTimer = timer
        timer.activate()
    }

    private func pollRealtimeStats() {
        guard let chain = dspChain else { return }

        var meters = DSPChainMeters(
            inputPeak: 0,
            inputRMS: 0,
            outputPeak: 0,
            outputRMS: 0,
            gainReductionDB: 0,
            clippedSamples: 0
        )
        dsp_chain_copy_meters(chain, &meters)

        inputPeak = meters.inputPeak
        inputRMS = meters.inputRMS
        outputPeak = meters.outputPeak
        outputRMS = meters.outputRMS
        gainReductionDB = meters.gainReductionDB
        clippedSamples = meters.clippedSamples

        if let ring = monitorWriter {
            var stats = VMRealtimeStats(overruns: 0, underruns: 0, frameClock: 0, writeIndex: 0, readIndex: 0)
            vm_ring_get_stats(ring, &stats)

            xrunsOverruns = stats.overruns
            xrunsUnderruns = 0

            if stats.overruns > 20 {
                warningMessage = "Realtime dropouts detected (xruns: \(stats.overruns)). Increase latency/quality slider toward Quality."
            }

            if !xrunAutoFallbackTriggered && stats.overruns > 50 && currentSettings.denoiseEnabled {
                xrunAutoFallbackTriggered = true
                currentSettings.denoiseEnabled = false
                warningMessage = "Denoise auto-disabled to protect realtime stability."
                pushParametersToDSP()
            }
        }

        if selectedSampleRate == .hz48k, let ring = monitorWriter {
            let ringRate = vm_ring_get_sample_rate(ring)
            if ringRate != 48_000 {
                warningMessage = "Sample-rate mismatch: engine at \(ringRate) Hz while UI is set to 48 kHz."
            }
        }

        let now = CACurrentMediaTime()
        if isRunning && now >= inputWatchdogGraceUntil && (now - lastInputTapTime) > 1.0 {
            if inputRecoveryAttempts == 0 {
                inputRecoveryAttempts = 1
                warningMessage = Self.recoveringInputWarning
                restartForInputStall()
                return
            }
            warningMessage = Self.noInputFramesWarning
        } else if warningMessage == Self.noInputFramesWarning && (now - lastInputTapTime) <= 0.5 {
            warningMessage = nil
        } else if warningMessage == Self.recoveringInputWarning && (now - lastInputTapTime) <= 0.5 {
            warningMessage = nil
        }
    }

    private func restartForConfigurationChange() {
        suppressInputWatchdog(for: 2.0)
        let wasRunning = isRunning
        stop()
        if wasRunning {
            startEngine(resetInputRecovery: true)
        }
    }

    private func restartForRouteChange() {
        suppressInputWatchdog(for: 4.0)
        warningMessage = "Reconfiguring audio route..."
        let wasRunning = isRunning
        stop()
        if wasRunning {
            startEngine(resetInputRecovery: true)
        }
    }

    private func restartForInputStall() {
        suppressInputWatchdog(for: 3.0)
        let wasRunning = isRunning
        stop()
        if wasRunning {
            startEngine(resetInputRecovery: false)
        }
    }

    private func suppressInputWatchdog(for seconds: TimeInterval) {
        inputWatchdogGraceUntil = CACurrentMediaTime() + max(0, seconds)
    }

    private func startObservingHardwareChanges() {
        guard hardwareListenerBlock == nil else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleHardwareRefresh()
        }
        hardwareListenerBlock = listener

        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectAddPropertyListenerBlock(systemObject, &address, hardwareObserverQueue, listener)
        }
    }

    private func stopObservingHardwareChanges() {
        pendingHardwareRefresh?.cancel()
        pendingHardwareRefresh = nil

        guard let listener = hardwareListenerBlock else { return }

        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(systemObject, &address, hardwareObserverQueue, listener)
        }

        hardwareListenerBlock = nil
    }

    private func scheduleHardwareRefresh() {
        pendingHardwareRefresh?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.handleHardwareRefresh()
        }
        pendingHardwareRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func handleHardwareRefresh() {
        let previousInput = selectedInputDeviceID
        let previousOutput = selectedMonitorDeviceID

        refreshInputDevices()

        guard isRunning else { return }

        let defaultInput = AudioDeviceCatalog.defaultInputDeviceID()
        if defaultInput != 0, selectedInputDeviceID != 0, defaultInput != selectedInputDeviceID {
            warningMessage = "Restoring selected microphone after system route change..."
            restartForRouteChange()
            return
        }

        if previousOutput != selectedMonitorDeviceID {
            restartForRouteChange()
            return
        }

        if previousInput != selectedInputDeviceID {
            warningMessage = "Selected microphone changed. Restart to use the new input device."
        }
    }

    private func closeRing(_ ring: inout OpaquePointer?) {
        if let handle = ring {
            vm_ring_close(handle)
            ring = nil
        }
    }
}

private enum AudioEngineError: LocalizedError {
    case halComponentUnavailable
    case halConfigurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .halComponentUnavailable:
            return "HAL microphone capture component is unavailable."
        case .halConfigurationFailed(let message):
            return message
        }
    }
}
