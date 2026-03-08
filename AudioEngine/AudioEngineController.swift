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
    @Published var selectedOutputDeviceID: AudioDeviceID = 0
    @Published var selectedMonitorDeviceID: AudioDeviceID = 0
    @Published var selectedSampleRate: SampleRateOption = .auto
    @Published var selectedBufferSize: BufferSizeOption = .auto

    @Published var monitorEnabled = false
    @Published var monitorLevel: Float = 0.2
    @Published var latencyQuality: Float = 0.55

    @Published var inputPeak: Float = 0
    @Published var inputRMS: Float = 0
    @Published var outputPeak: Float = 0
    @Published var outputRMS: Float = 0
    @Published var compressorInputRMS: Float = 0
    @Published var compressorOutputRMS: Float = 0
    @Published var gainReductionDB: Float = 0
    @Published var clippedSamples: UInt32 = 0

    @Published var xrunsOverruns: UInt32 = 0
    @Published var xrunsUnderruns: UInt32 = 0
    @Published var warningMessage: String?
    @Published var routeStatus = "No output"

    private let maxFramesPerBuffer = 2048
    private let routeRingName = "/macaudio-out"
    private let monitorRingName = "/macaudio-mon"
    private let hardwareObserverQueue = DispatchQueue(label: "com.skylarenns.macaudio.hardware", qos: .utility)
    private let controlQueue = DispatchQueue(label: "com.skylarenns.macaudio.control", qos: .userInitiated)
    private let restartLock = NSLock()

    private var dspChain: OpaquePointer?
    private var inputUnit: AudioUnit?
    private var routeOutputUnit: AudioUnit?
    private var monitorOutputUnit: AudioUnit?

    private var routeWriter: OpaquePointer?
    private var routeReader: OpaquePointer?
    private var monitorWriter: OpaquePointer?
    private var monitorReader: OpaquePointer?

    private var processScratch: UnsafeMutablePointer<Float>
    private var routeScratch: UnsafeMutablePointer<Float>
    private var monitorScratch: UnsafeMutablePointer<Float>
    private var inputBufferListPointer: UnsafeMutablePointer<AudioBufferList>?

    private var meterTimer: DispatchSourceTimer?
    private var lastInputTapTime: TimeInterval = 0
    private var inputWatchdogGraceUntil: TimeInterval = 0
    private var hardwareListenerBlock: AudioObjectPropertyListenerBlock?
    private var pendingHardwareRefresh: DispatchWorkItem?

    private var currentSettings = VoicePreset.cleanVoice.settings
    private var xrunAutoFallbackTriggered = false
    private var inputRecoveryAttempts = 0

    private var routeOutputContext: OutputRenderContext?
    private var monitorOutputContext: OutputRenderContext?
    private var restartGeneration: UInt64 = 0

    init() {
        processScratch = .allocate(capacity: maxFramesPerBuffer)
        routeScratch = .allocate(capacity: maxFramesPerBuffer)
        monitorScratch = .allocate(capacity: maxFramesPerBuffer)
        startObservingHardwareChanges()
        refreshInputDevices()
    }

    deinit {
        stopObservingHardwareChanges()
        stop()
        processScratch.deallocate()
        routeScratch.deallocate()
        monitorScratch.deallocate()
    }

    var effectiveBufferFrames: UInt32 {
        if let explicit = selectedBufferSize.frames {
            return explicit
        }
        if latencyQuality < 0.34 {
            return 256
        }
        if latencyQuality < 0.67 {
            return 128
        }
        return 64
    }

    func refreshInputDevices() {
        availableInputDevices = AudioDeviceCatalog.listInputDevices()
        availableOutputDevices = AudioDeviceCatalog.listOutputDevices()

        let inputFallback = AudioDeviceCatalog.defaultInputDeviceID()
        if selectedInputDeviceID == 0 || !availableInputDevices.contains(where: { $0.id == selectedInputDeviceID }) {
            selectedInputDeviceID = inputFallback
        }

        let outputFallback = AudioDeviceCatalog.preferredOutputDeviceID()
        if selectedOutputDeviceID == 0 || !availableOutputDevices.contains(where: { $0.id == selectedOutputDeviceID }) {
            selectedOutputDeviceID = outputFallback
        }

        if selectedMonitorDeviceID == 0 || !availableOutputDevices.contains(where: { $0.id == selectedMonitorDeviceID }) {
            selectedMonitorDeviceID = AudioDeviceCatalog.defaultOutputDeviceID()
        }

        routeStatus = selectedOutputDeviceID == 0 ? "No output" : AudioDeviceCatalog.deviceName(selectedOutputDeviceID)
    }

    func setPreset(_ preset: VoicePreset) {
        currentSettings = preset.settings
        pushParametersToDSP()
    }

    func updateSettings(_ settings: VoiceProcessingSettings) {
        currentSettings = settings
        pushParametersToDSP()
    }

    func start() {
        let generation = nextRestartGeneration()
        controlQueue.async { [weak self] in
            guard let self, self.isRestartCurrent(generation) else { return }
            self.startEngine(resetInputRecovery: true)
        }
    }

    func stop() {
        let generation = nextRestartGeneration()
        controlQueue.async { [weak self] in
            guard let self, self.isRestartCurrent(generation) else { return }
            self.stopSynchronously()
        }
    }

    private func stopSynchronously() {
        meterTimer?.cancel()
        meterTimer = nil

        stopOutputUnit(&routeOutputUnit)
        stopOutputUnit(&monitorOutputUnit)
        stopInputUnit()

        routeOutputContext = nil
        monitorOutputContext = nil

        if let chain = dspChain {
            dsp_chain_destroy(chain)
            dspChain = nil
        }

        closeRing(&routeWriter)
        closeRing(&routeReader)
        closeRing(&monitorWriter)
        closeRing(&monitorReader)

        publish { self.isRunning = false }
    }

    func applyLatencyQuality(_ value: Float) {
        latencyQuality = min(max(value, 0), 1)
        if currentSettings.denoiseEnabled {
            let maxStrength: Float = latencyQuality < 0.34 ? 0.18 : (latencyQuality < 0.67 ? 0.12 : 0.08)
            currentSettings.denoiseStrength = min(currentSettings.denoiseStrength, maxStrength)
        }
        pushParametersToDSP()
    }

    func updateOutputDevice(_ deviceID: AudioDeviceID) {
        selectedOutputDeviceID = deviceID
        routeStatus = selectedOutputDeviceID == 0 ? "No output" : AudioDeviceCatalog.deviceName(selectedOutputDeviceID)
        guard isRunning else { return }
        restartForConfigurationChange(message: "Switching route output...")
    }

    func updateMonitorDevice(_ deviceID: AudioDeviceID) {
        selectedMonitorDeviceID = deviceID
        guard isRunning, monitorEnabled else { return }
        restartForConfigurationChange(message: "Switching monitor output...")
    }

    func updateInputDevice(_ deviceID: AudioDeviceID) {
        selectedInputDeviceID = deviceID
        guard isRunning else { return }
        restartForConfigurationChange(message: "Switching microphone...")
    }

    func updateIOConfiguration(sampleRate: SampleRateOption, bufferSize: BufferSizeOption) {
        selectedSampleRate = sampleRate
        selectedBufferSize = bufferSize
        guard isRunning else { return }
        restartForConfigurationChange(message: "Applying audio settings...")
    }

    func setMonitorEnabled(_ enabled: Bool) {
        monitorEnabled = enabled
        guard isRunning else { return }
        restartForConfigurationChange(message: enabled ? "Enabling monitor..." : "Disabling monitor...")
    }

    private func startEngine(resetInputRecovery: Bool) {
        let startingState = syncOnMain {
            self.refreshInputDevices()
            return (
                isRunning: self.isRunning,
                selectedInput: self.selectedInputDeviceID,
                selectedOutput: self.selectedOutputDeviceID,
                selectedMonitor: self.selectedMonitorDeviceID,
                monitorEnabled: self.monitorEnabled,
                sampleRate: self.selectedSampleRate,
                bufferSize: self.selectedBufferSize,
                latencyQuality: self.latencyQuality
            )
        }

        guard !startingState.isRunning else { return }

        publish { self.warningMessage = nil }
        xrunAutoFallbackTriggered = false
        if resetInputRecovery {
            inputRecoveryAttempts = 0
        }

        let inputDeviceID = startingState.selectedInput == 0 ? AudioDeviceCatalog.defaultInputDeviceID() : startingState.selectedInput
        let outputDeviceID = startingState.selectedOutput == 0 ? AudioDeviceCatalog.preferredOutputDeviceID() : startingState.selectedOutput
        guard inputDeviceID != 0, outputDeviceID != 0 else {
            publish { self.warningMessage = "Connect an input and output device and retry." }
            return
        }

        let bufferFrames = effectiveBufferFrames(sampleRateOption: startingState.sampleRate, bufferSizeOption: startingState.bufferSize, latencyQuality: startingState.latencyQuality)
        let sampleRate = resolveSampleRate(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID,
            requestedRate: startingState.sampleRate
        )
        configureDeviceIO(deviceID: inputDeviceID, sampleRate: sampleRate, frameSize: bufferFrames)
        configureDeviceIO(deviceID: outputDeviceID, sampleRate: sampleRate, frameSize: bufferFrames)
        if startingState.monitorEnabled, startingState.selectedMonitor != 0 {
            configureDeviceIO(deviceID: startingState.selectedMonitor, sampleRate: sampleRate, frameSize: bufferFrames)
        }

        setupRingBuffers(sampleRate: sampleRate)

        dspChain = dsp_chain_create(sampleRate, 1)
        pushParametersToDSP()

        do {
            try setupInputUnit(deviceID: inputDeviceID, sampleRate: sampleRate)
            try setupOutputUnit(deviceID: outputDeviceID, sampleRate: sampleRate, kind: .route)
            if startingState.monitorEnabled, startingState.selectedMonitor != 0 {
                try setupOutputUnit(deviceID: startingState.selectedMonitor, sampleRate: sampleRate, kind: .monitor)
            }
            try startInputUnit()
            try startOutputUnits()
            publish {
                self.isRunning = true
                self.routeStatus = AudioDeviceCatalog.deviceName(outputDeviceID)
            }
            lastInputTapTime = CACurrentMediaTime()
            inputWatchdogGraceUntil = lastInputTapTime + 3.0
            startMeterTimer()
        } catch {
            publish { self.warningMessage = error.localizedDescription }
            stopSynchronously()
        }
    }

    private func resolveSampleRate(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID, requestedRate: SampleRateOption) -> Double {
        if let explicit = requestedRate.sampleRate {
            return explicit
        }
        return AudioDeviceCatalog.nominalSampleRate(deviceID: outputDeviceID)
            ?? AudioDeviceCatalog.nominalSampleRate(deviceID: inputDeviceID)
            ?? 48_000
    }

    private func configureDeviceIO(deviceID: AudioDeviceID, sampleRate: Double, frameSize: UInt32) {
        _ = AudioDeviceCatalog.setNominalSampleRate(deviceID: deviceID, sampleRate: sampleRate)
        _ = AudioDeviceCatalog.setBufferFrameSize(deviceID: deviceID, frameSize: frameSize)
    }

    private func setupRingBuffers(sampleRate: Double) {
        _ = routeRingName.withCString { vm_ring_unlink($0) }
        _ = monitorRingName.withCString { vm_ring_unlink($0) }

        closeRing(&routeWriter)
        closeRing(&routeReader)
        closeRing(&monitorWriter)
        closeRing(&monitorReader)

        var routeWriter: OpaquePointer?
        let routeWriterResult = routeRingName.withCString { vm_ring_create_writer($0, 8192, 1, &routeWriter) }
        guard routeWriterResult == 0, let routeWriter else {
            publish { self.warningMessage = "Output route buffer failed (\(routeWriterResult))." }
            return
        }
        vm_ring_set_sample_rate(routeWriter, UInt32(sampleRate))
        self.routeWriter = routeWriter

        var routeReader: OpaquePointer?
        let routeReaderResult = routeRingName.withCString { vm_ring_open_reader($0, &routeReader) }
        if routeReaderResult == 0, let routeReader {
            self.routeReader = routeReader
        }

        var monitorWriter: OpaquePointer?
        let monitorWriterResult = monitorRingName.withCString { vm_ring_create_writer($0, 8192, 1, &monitorWriter) }
        if monitorWriterResult == 0, let monitorWriter {
            vm_ring_set_sample_rate(monitorWriter, UInt32(sampleRate))
            self.monitorWriter = monitorWriter
        }

        var monitorReader: OpaquePointer?
        let monitorReaderResult = monitorRingName.withCString { vm_ring_open_reader($0, &monitorReader) }
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

        if let routeWriter {
            _ = vm_ring_write(routeWriter, processScratch, UInt32(frameCount))
        }
        if monitorEnabled, let monitorWriter {
            _ = vm_ring_write(monitorWriter, processScratch, UInt32(frameCount))
        }
    }

    private func setupInputUnit(deviceID: AudioDeviceID, sampleRate: Double) throws {
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
        var disableOutput: UInt32 = 0
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, UInt32(MemoryLayout<UInt32>.size)) == noErr,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput, UInt32(MemoryLayout<UInt32>.size)) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not configure microphone capture.")
        }

        var mutableDeviceID = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not bind the selected microphone.")
        }

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

        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not configure microphone stream format.")
        }

        var callback = AURenderCallbackStruct(inputProc: AudioEngineController.inputRenderCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not install microphone callback.")
        }

        var maxFrames = UInt32(maxFramesPerBuffer)
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))

        allocateInputBufferList()

        guard AudioUnitInitialize(unit) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not initialize microphone capture.")
        }
    }

    private func setupOutputUnit(deviceID: AudioDeviceID, sampleRate: Double, kind: OutputRenderKind) throws {
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

        var enableOutput: UInt32 = 1
        var disableInput: UInt32 = 0
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOutput, UInt32(MemoryLayout<UInt32>.size)) == noErr,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableInput, UInt32(MemoryLayout<UInt32>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioEngineError.halConfigurationFailed("Could not configure output device.")
        }

        var mutableDeviceID = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioEngineError.halConfigurationFailed("Could not bind the selected output device.")
        }

        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioEngineError.halConfigurationFailed("Could not configure output stream format.")
        }

        let context = OutputRenderContext(controller: self, kind: kind)
        var callback = AURenderCallbackStruct(
            inputProc: AudioEngineController.outputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioEngineError.halConfigurationFailed("Could not install output callback.")
        }

        var maxFrames = UInt32(maxFramesPerBuffer)
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))

        guard AudioUnitInitialize(unit) == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioEngineError.halConfigurationFailed("Could not initialize output device.")
        }

        switch kind {
        case .route:
            routeOutputUnit = unit
            routeOutputContext = context
        case .monitor:
            monitorOutputUnit = unit
            monitorOutputContext = context
        }
    }

    private func startInputUnit() throws {
        guard let inputUnit else {
            throw AudioEngineError.halConfigurationFailed("Microphone capture is not configured.")
        }
        guard AudioOutputUnitStart(inputUnit) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not start microphone capture.")
        }
    }

    private func startOutputUnits() throws {
        guard let routeOutputUnit else {
            throw AudioEngineError.halConfigurationFailed("Output route is not configured.")
        }
        guard AudioOutputUnitStart(routeOutputUnit) == noErr else {
            throw AudioEngineError.halConfigurationFailed("Could not start output route.")
        }
        if let monitorOutputUnit, AudioOutputUnitStart(monitorOutputUnit) != noErr {
            throw AudioEngineError.halConfigurationFailed("Could not start monitor output.")
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

    private func stopOutputUnit(_ unit: inout AudioUnit?) {
        guard let audioUnit = unit else { return }
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        unit = nil
    }

    private func allocateInputBufferList() {
        inputBufferListPointer?.deallocate()
        let pointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        pointer.initialize(to: AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(maxFramesPerBuffer * MemoryLayout<Float>.size),
                mData: processScratch
            )
        ))
        inputBufferListPointer = pointer
    }

    private static let inputRenderCallback: AURenderCallback = { refCon, ioActionFlags, timeStamp, _, frameCount, _ in
        let controller = Unmanaged<AudioEngineController>.fromOpaque(refCon).takeUnretainedValue()
        return controller.renderInput(ioActionFlags: ioActionFlags, timeStamp: timeStamp, frameCount: frameCount)
    }

    private func renderInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard let inputUnit, let inputBufferListPointer, frameCount > 0, Int(frameCount) <= maxFramesPerBuffer else {
            return noErr
        }

        let buffers = UnsafeMutableAudioBufferListPointer(inputBufferListPointer)
        buffers[0].mData = UnsafeMutableRawPointer(processScratch)
        buffers[0].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)

        let status = AudioUnitRender(inputUnit, ioActionFlags, timeStamp, 1, frameCount, inputBufferListPointer)
        guard status == noErr else { return status }

        handleInputFrames(frameCount: Int(frameCount))
        return noErr
    }

    private static let outputRenderCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
        guard let ioData else { return noErr }
        let context = Unmanaged<OutputRenderContext>.fromOpaque(refCon).takeUnretainedValue()
        return context.controller.renderOutput(kind: context.kind, frameCount: Int(frameCount), ioData: ioData)
    }

    private func renderOutput(kind: OutputRenderKind, frameCount: Int, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard frameCount > 0 && frameCount <= maxFramesPerBuffer else { return noErr }

        let scratch: UnsafeMutablePointer<Float>
        let reader: OpaquePointer?
        let gain: Float

        switch kind {
        case .route:
            scratch = routeScratch
            reader = routeReader
            gain = 1.0
        case .monitor:
            scratch = monitorScratch
            reader = monitorReader
            gain = monitorLevel
        }

        var readFrames = 0
        if let reader {
            readFrames = Int(vm_ring_read(reader, scratch, UInt32(frameCount)))
        }

        let limitedGain = min(max(gain, 0), 2)
        let safeCeiling: Float = 0.98
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for bufferIndex in 0..<buffers.count {
            guard let mData = buffers[bufferIndex].mData else { continue }
            let out = mData.assumingMemoryBound(to: Float.self)

            for frame in 0..<readFrames {
                var sample = scratch[frame] * limitedGain
                sample = max(min(sample, safeCeiling), -safeCeiling)
                out[frame] = sample
            }
            if readFrames < frameCount {
                out.advanced(by: readFrames).initialize(repeating: 0, count: frameCount - readFrames)
            }
        }
        return noErr
    }

    private func pushParametersToDSP() {
        guard let chain = dspChain else { return }

        var params = DSPChainParameters()
        params.inputGainDB = currentSettings.inputGainDB
        params.eqEnabled = currentSettings.eqEnabled
        params.highPassEnabled = currentSettings.highPassEnabled
        params.highPassHz = currentSettings.highPassHz
        params.band1Enabled = currentSettings.band1Enabled
        params.band1FrequencyHz = currentSettings.band1FrequencyHz
        params.band1GainDB = currentSettings.band1GainDB
        params.band1Q = currentSettings.band1Q
        params.band2Enabled = currentSettings.band2Enabled
        params.band2FrequencyHz = currentSettings.band2FrequencyHz
        params.band2GainDB = currentSettings.band2GainDB
        params.band2Q = currentSettings.band2Q
        params.band3Enabled = currentSettings.band3Enabled
        params.band3FrequencyHz = currentSettings.band3FrequencyHz
        params.band3GainDB = currentSettings.band3GainDB
        params.band3Q = currentSettings.band3Q
        params.compressorEnabled = currentSettings.compressorEnabled
        params.compressorThresholdDB = currentSettings.compressorThresholdDB
        params.compressorRatio = currentSettings.compressorRatio
        params.compressorAttackMs = currentSettings.compressorAttackMs
        params.compressorReleaseMs = currentSettings.compressorReleaseMs
        params.makeupGainDB = currentSettings.makeupGainDB
        params.limiterEnabled = currentSettings.limiterEnabled
        params.limiterCeilingDB = currentSettings.limiterCeilingDB
        params.outputGainDB = currentSettings.outputGainDB
        params.denoiseEnabled = currentSettings.denoiseEnabled
        params.denoiseStrength = min(currentSettings.denoiseStrength, 0.18)
        params.gateEnabled = currentSettings.gateEnabled
        params.gateThresholdDB = currentSettings.gateThresholdDB
        params.gateAttackMs = currentSettings.gateAttackMs
        params.gateReleaseMs = currentSettings.gateReleaseMs
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
            compressorInputRMS: 0,
            compressorOutputRMS: 0,
            gainReductionDB: 0,
            clippedSamples: 0
        )
        dsp_chain_copy_meters(chain, &meters)

        inputPeak = meters.inputPeak
        inputRMS = meters.inputRMS
        outputPeak = meters.outputPeak
        outputRMS = meters.outputRMS
        compressorInputRMS = meters.compressorInputRMS
        compressorOutputRMS = meters.compressorOutputRMS
        gainReductionDB = meters.gainReductionDB
        clippedSamples = meters.clippedSamples

        if let ring = routeWriter {
            var stats = VMRealtimeStats(overruns: 0, underruns: 0, frameClock: 0, writeIndex: 0, readIndex: 0)
            vm_ring_get_stats(ring, &stats)
            xrunsOverruns = stats.overruns
            xrunsUnderruns = 0
            if stats.overruns > 20 {
                warningMessage = "Realtime dropouts detected (xruns: \(stats.overruns)). Increase latency toward Quality."
            }
            if !xrunAutoFallbackTriggered && stats.overruns > 50 && currentSettings.denoiseEnabled {
                xrunAutoFallbackTriggered = true
                currentSettings.denoiseEnabled = false
                currentSettings.denoiseStrength = 0
                warningMessage = "Denoise auto-disabled to protect realtime stability."
                pushParametersToDSP()
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
        } else if (warningMessage == Self.noInputFramesWarning || warningMessage == Self.recoveringInputWarning) && (now - lastInputTapTime) <= 0.5 {
            warningMessage = nil
        }
    }

    private func restartForConfigurationChange(message: String? = nil) {
        suppressInputWatchdog(for: 3.0)
        warningMessage = message
        let wasRunning = isRunning
        guard wasRunning else { return }

        let generation = nextRestartGeneration()
        controlQueue.async { [weak self] in
            guard let self, self.isRestartCurrent(generation) else { return }
            self.stopSynchronously()
            guard self.isRestartCurrent(generation) else { return }
            self.startEngine(resetInputRecovery: true)
        }
    }

    private func restartForInputStall() {
        suppressInputWatchdog(for: 3.0)
        let wasRunning = isRunning
        guard wasRunning else { return }

        let generation = nextRestartGeneration()
        controlQueue.async { [weak self] in
            guard let self, self.isRestartCurrent(generation) else { return }
            self.stopSynchronously()
            guard self.isRestartCurrent(generation) else { return }
            self.startEngine(resetInputRecovery: false)
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
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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
        let previousOutput = selectedOutputDeviceID
        let previousMonitor = selectedMonitorDeviceID
        refreshInputDevices()

        guard isRunning else { return }

        let outputMissing = !availableOutputDevices.contains(where: { $0.id == previousOutput })
        let inputMissing = !availableInputDevices.contains(where: { $0.id == previousInput })
        let monitorMissing = monitorEnabled && !availableOutputDevices.contains(where: { $0.id == previousMonitor })

        if inputMissing || outputMissing || monitorMissing {
            restartForConfigurationChange(message: "Audio devices changed. Rebuilding route...")
        }
    }

    private func closeRing(_ ring: inout OpaquePointer?) {
        if let handle = ring {
            vm_ring_close(handle)
            ring = nil
        }
    }

    private func effectiveBufferFrames(sampleRateOption: SampleRateOption, bufferSizeOption: BufferSizeOption, latencyQuality: Float) -> UInt32 {
        if let explicit = bufferSizeOption.frames {
            return explicit
        }
        if latencyQuality < 0.34 {
            return 256
        }
        if latencyQuality < 0.67 {
            return 128
        }
        return 64
    }

    private func nextRestartGeneration() -> UInt64 {
        restartLock.lock()
        defer { restartLock.unlock() }
        restartGeneration += 1
        return restartGeneration
    }

    private func isRestartCurrent(_ generation: UInt64) -> Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        return restartGeneration == generation
    }

    private func publish(_ update: @escaping () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func syncOnMain<T>(_ block: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return block()
        }
        return DispatchQueue.main.sync(execute: block)
    }
}

private final class OutputRenderContext {
    unowned let controller: AudioEngineController
    let kind: OutputRenderKind

    init(controller: AudioEngineController, kind: OutputRenderKind) {
        self.controller = controller
        self.kind = kind
    }
}

private enum OutputRenderKind {
    case route
    case monitor
}

private enum AudioEngineError: LocalizedError {
    case halComponentUnavailable
    case halConfigurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .halComponentUnavailable:
            return "Required CoreAudio HAL component is unavailable."
        case .halConfigurationFailed(let message):
            return message
        }
    }
}
