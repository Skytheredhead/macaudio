import AudioToolbox
@preconcurrency import AVFoundation
import Combine
import CoreAudio
import Foundation
import QuartzCore

final class AudioEngineController: ObservableObject, @unchecked Sendable {
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
    @Published private(set) var transportState: AudioTransportState = .stopped

    private let maxFramesPerBuffer = 2048
    private let routeRingName = "/macaudio-out"
    private let monitorRingName = "/macaudio-mon"
    private let hardwareObserverQueue = DispatchQueue(label: "com.skylarenns.macaudio.hardware", qos: .utility)
    private let controlQueue = DispatchQueue(label: "com.skylarenns.macaudio.control", qos: .userInitiated)
    private let controlQueueKey = DispatchSpecificKey<UInt8>()
    private let restartLock = NSLock()
    private let realtimeSnapshotLock = NSLock()

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
    private var stereoLeftScratch: UnsafeMutablePointer<Float>
    private var stereoRightScratch: UnsafeMutablePointer<Float>
    private var insertInputLeftScratch: UnsafeMutablePointer<Float>
    private var insertInputRightScratch: UnsafeMutablePointer<Float>
    private var interleavedStereoScratch: UnsafeMutablePointer<Float>
    private var inputBufferListPointer: UnsafeMutablePointer<AudioBufferList>?

    private var meterTimer: DispatchSourceTimer?
    private var lastInputTapTime: TimeInterval = 0
    private var inputWatchdogGraceUntil: TimeInterval = 0
    private var hardwareListenerBlock: AudioObjectPropertyListenerBlock?
    private var pendingHardwareRefresh: DispatchWorkItem?

    private var currentSettings = VoicePreset.cleanVoice.settings
    private var xrunAutoFallbackTriggered = false
    private var inputRecoveryAttempts = 0
    private var pendingInsertPlugins: [InsertChainStage] = []
    private var pendingInsertSignature: [String] = []
    private var activeInsertSignature: [String] = []
    private var activeInsertChain: HostedAudioUnitInsertChain?
    private var pluginRenderSampleTime: Double = 0
    private var latestRealtimeSnapshot = RealtimeMeterSnapshot()

    private var routeOutputContext: OutputRenderContext?
    private var monitorOutputContext: OutputRenderContext?
    private var restartGeneration: UInt64 = 0

    init() {
        processScratch = .allocate(capacity: maxFramesPerBuffer)
        routeScratch = .allocate(capacity: maxFramesPerBuffer * 2)
        monitorScratch = .allocate(capacity: maxFramesPerBuffer * 2)
        stereoLeftScratch = .allocate(capacity: maxFramesPerBuffer)
        stereoRightScratch = .allocate(capacity: maxFramesPerBuffer)
        insertInputLeftScratch = .allocate(capacity: maxFramesPerBuffer)
        insertInputRightScratch = .allocate(capacity: maxFramesPerBuffer)
        interleavedStereoScratch = .allocate(capacity: maxFramesPerBuffer * 2)
        controlQueue.setSpecific(key: controlQueueKey, value: 1)
        startObservingHardwareChanges()
        refreshInputDevices()
    }

    deinit {
        stopObservingHardwareChanges()
        stop()
        processScratch.deallocate()
        routeScratch.deallocate()
        monitorScratch.deallocate()
        stereoLeftScratch.deallocate()
        stereoRightScratch.deallocate()
        insertInputLeftScratch.deallocate()
        insertInputRightScratch.deallocate()
        interleavedStereoScratch.deallocate()
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

    var transportButtonTitle: String {
        switch transportState {
        case .stopped:
            return "Start"
        case .starting:
            return "Starting"
        case .running:
            return "Stop"
        case .stopping:
            return "Stopping"
        }
    }

    var isTransportTransitioning: Bool {
        switch transportState {
        case .starting, .stopping:
            return true
        case .stopped, .running:
            return false
        }
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

    func updateInsertChain(_ plugins: [InsertChainStage]) {
        pendingInsertPlugins = plugins
        pendingInsertSignature = insertSignature(for: plugins)
        guard isRunning else { return }
        guard pendingInsertSignature != activeInsertSignature else { return }
        restartForConfigurationChange(message: "Updating insert chain...")
    }

    func liveAudioUnit(for boxID: UUID) -> AVAudioUnit? {
        controlQueueSync {
            activeInsertChain?.liveAudioUnit(for: boxID)
        }
    }

    func liveProcessorPlugin(for boxID: UUID) -> PluginDescriptor? {
        controlQueueSync {
            activeInsertChain?.processorPlugin(for: boxID)
        }
    }

    func start() {
        guard !isRunning, transportState != .starting else { return }
        publish { self.transportState = .starting }
        let generation = nextRestartGeneration()
        controlQueue.async { [weak self] in
            guard let self, self.isRestartCurrent(generation) else { return }
            self.startEngine(resetInputRecovery: true)
        }
    }

    func stop() {
        guard isRunning || transportState == .starting else {
            publish { self.transportState = .stopped }
            return
        }
        publish { self.transportState = .stopping }
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
        releaseInsertChain()
        activeInsertSignature = []
        withRealtimeSnapshotLock {
            latestRealtimeSnapshot = RealtimeMeterSnapshot()
        }

        closeRing(&routeWriter)
        closeRing(&routeReader)
        closeRing(&monitorWriter)
        closeRing(&monitorReader)

        publish {
            self.isRunning = false
            self.transportState = .stopped
        }
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

        guard !startingState.isRunning else {
            publish { self.transportState = .running }
            return
        }

        publish { self.warningMessage = nil }
        xrunAutoFallbackTriggered = false
        if resetInputRecovery {
            inputRecoveryAttempts = 0
        }
        withRealtimeSnapshotLock {
            latestRealtimeSnapshot = RealtimeMeterSnapshot()
        }

        let inputDeviceID = startingState.selectedInput == 0 ? AudioDeviceCatalog.defaultInputDeviceID() : startingState.selectedInput
        let outputDeviceID = startingState.selectedOutput == 0 ? AudioDeviceCatalog.preferredOutputDeviceID() : startingState.selectedOutput
        guard inputDeviceID != 0, outputDeviceID != 0 else {
            publish {
                self.warningMessage = "Connect an input and output device and retry."
                self.transportState = .stopped
            }
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
            try buildInsertChain(sampleRate: sampleRate)
        } catch {
            publish { self.warningMessage = error.localizedDescription }
            releaseInsertChain()
            activeInsertSignature = []
        }
        pluginRenderSampleTime = 0

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
                self.transportState = .running
                self.routeStatus = AudioDeviceCatalog.deviceName(outputDeviceID)
            }
            lastInputTapTime = CACurrentMediaTime()
            inputWatchdogGraceUntil = lastInputTapTime + 3.0
            startMeterTimer()
        } catch {
            publish {
                self.warningMessage = error.localizedDescription
                self.transportState = .stopped
            }
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
        let routeWriterResult = routeRingName.withCString { vm_ring_create_writer($0, 8192, 2, &routeWriter) }
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
        let monitorWriterResult = monitorRingName.withCString { vm_ring_create_writer($0, 8192, 2, &monitorWriter) }
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

        for frame in 0..<frameCount {
            let sample = processScratch[frame]
            stereoLeftScratch[frame] = sample
            stereoRightScratch[frame] = sample
        }

        processInsertChain(frameCount: UInt32(frameCount))
        interleaveStereo(frameCount: frameCount)
        updateRealtimeSnapshot(frameCount: frameCount)

        if let routeWriter {
            _ = vm_ring_write(routeWriter, interleavedStereoScratch, UInt32(frameCount))
        }
        if monitorEnabled, let monitorWriter {
            _ = vm_ring_write(monitorWriter, interleavedStereoScratch, UInt32(frameCount))
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
        let channels = max(1, Int(reader.map(vm_ring_get_channels) ?? 2))
        for bufferIndex in 0..<buffers.count {
            guard let mData = buffers[bufferIndex].mData else { continue }
            let out = mData.assumingMemoryBound(to: Float.self)
            let sourceChannel = min(bufferIndex, channels - 1)

            for frame in 0..<readFrames {
                let sampleIndex = frame * channels + sourceChannel
                var sample = scratch[sampleIndex] * limitedGain
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

    private func buildInsertChain(sampleRate: Double) throws {
        releaseInsertChain()
        guard !pendingInsertPlugins.isEmpty else {
            activeInsertSignature = []
            return
        }

        var insertStages: [InsertChainStage] = []
        var failedPluginNames: [String] = []

        for stage in pendingInsertPlugins {
            if stage.processorPlugin.audioUnitComponentDescription != nil {
                insertStages.append(stage)
            } else {
                failedPluginNames.append(stage.assignedPlugin.name)
            }
        }

        if !insertStages.isEmpty {
            activeInsertChain = try HostedAudioUnitInsertChain(
                stages: insertStages,
                sampleRate: sampleRate,
                maximumFrames: UInt32(maxFramesPerBuffer)
            )
            activeInsertSignature = pendingInsertSignature
        } else {
            activeInsertChain = nil
            activeInsertSignature = []
        }
        if !failedPluginNames.isEmpty {
            let failedList = failedPluginNames.joined(separator: ", ")
            publish {
                self.warningMessage = "Some plug-ins could not be loaded into the live chain: \(failedList)"
            }
        }
    }

    private func releaseInsertChain() {
        activeInsertChain?.teardown()
        activeInsertChain = nil
    }

    private func processInsertChain(frameCount: UInt32) {
        guard let activeInsertChain else { return }

        memcpy(insertInputLeftScratch, stereoLeftScratch, Int(frameCount) * MemoryLayout<Float>.size)
        memcpy(insertInputRightScratch, stereoRightScratch, Int(frameCount) * MemoryLayout<Float>.size)
        let status = activeInsertChain.process(
            frameCount: frameCount,
            sampleTime: pluginRenderSampleTime,
            inputLeft: insertInputLeftScratch,
            inputRight: insertInputRightScratch,
            outputLeft: stereoLeftScratch,
            outputRight: stereoRightScratch
        )
        if status != noErr {
            memcpy(stereoLeftScratch, insertInputLeftScratch, Int(frameCount) * MemoryLayout<Float>.size)
            memcpy(stereoRightScratch, insertInputRightScratch, Int(frameCount) * MemoryLayout<Float>.size)
        }

        pluginRenderSampleTime += Double(frameCount)
    }

    private func interleaveStereo(frameCount: Int) {
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            interleavedStereoScratch[(frame * 2)] = stereoLeftScratch[frame]
            interleavedStereoScratch[(frame * 2) + 1] = stereoRightScratch[frame]
        }
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
        let realtimeSnapshot = withRealtimeSnapshotLock { latestRealtimeSnapshot }

        inputPeak = meters.inputPeak
        inputRMS = meters.inputRMS
        outputPeak = realtimeSnapshot.outputPeak
        outputRMS = realtimeSnapshot.outputRMS
        compressorInputRMS = meters.compressorInputRMS
        compressorOutputRMS = meters.compressorOutputRMS
        gainReductionDB = meters.gainReductionDB
        clippedSamples = max(meters.clippedSamples, realtimeSnapshot.clippedSamples)

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

    private func publish(_ update: @Sendable @escaping () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func controlQueueSync<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: controlQueueKey) != nil {
            return block()
        }
        return controlQueue.sync(execute: block)
    }

    private func syncOnMain<T>(_ block: @Sendable @escaping () -> T) -> T {
        if Thread.isMainThread {
            return block()
        }
        return DispatchQueue.main.sync(execute: block)
    }

    private func insertSignature(for plugins: [InsertChainStage]) -> [String] {
        plugins.map { stage in
            [
                stage.boxID.uuidString,
                stage.assignedPlugin.id,
                stage.processorPlugin.id
            ].joined(separator: "|")
        }
    }

    private func updateRealtimeSnapshot(frameCount: Int) {
        guard frameCount > 0 else { return }

        var peak: Float = 0
        var rmsAccumulator: Double = 0
        var clipped: UInt32 = 0

        for frame in 0..<frameCount {
            let left = stereoLeftScratch[frame]
            let right = stereoRightScratch[frame]
            peak = max(peak, abs(left), abs(right))
            rmsAccumulator += Double(left * left)
            rmsAccumulator += Double(right * right)
            if abs(left) > 0.98 || abs(right) > 0.98 {
                clipped &+= 1
            }
        }

        let rms = Float(sqrt(rmsAccumulator / Double(frameCount * 2)))
        withRealtimeSnapshotLock {
            latestRealtimeSnapshot.outputPeak = peak
            latestRealtimeSnapshot.outputRMS = rms
            latestRealtimeSnapshot.clippedSamples = latestRealtimeSnapshot.clippedSamples &+ clipped
        }
    }

    @discardableResult
    private func withRealtimeSnapshotLock<T>(_ block: () -> T) -> T {
        realtimeSnapshotLock.lock()
        defer { realtimeSnapshotLock.unlock() }
        return block()
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

enum AudioTransportState: Sendable {
    case stopped
    case starting
    case running
    case stopping
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

private struct RealtimeMeterSnapshot {
    var outputPeak: Float = 0
    var outputRMS: Float = 0
    var clippedSamples: UInt32 = 0
}

private final class HostedAudioUnitInsertChain {
    private struct HostedStage {
        let stage: InsertChainStage
        let audioUnit: AVAudioUnit
    }

    private final class RenderSourceState {
        var currentInputLeft: UnsafeMutablePointer<Float>?
        var currentInputRight: UnsafeMutablePointer<Float>?
        var currentFrameCount: Int = 0
        var readOffset: Int = 0

        func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2 else { return kAudio_ParamError }
            guard let inputLeft = currentInputLeft, let inputRight = currentInputRight else {
                for buffer in buffers {
                    if let data = buffer.mData {
                        data.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: Int(frameCount))
                    }
                }
                return noErr
            }

            let availableFrames = max(0, currentFrameCount - readOffset)
            let copyFrames = min(Int(frameCount), availableFrames)

            if let leftData = buffers[0].mData {
                memcpy(leftData, inputLeft.advanced(by: readOffset), copyFrames * MemoryLayout<Float>.size)
                if copyFrames < Int(frameCount) {
                    leftData.assumingMemoryBound(to: Float.self).advanced(by: copyFrames).initialize(repeating: 0, count: Int(frameCount) - copyFrames)
                }
                buffers[0].mDataByteSize = UInt32(Int(frameCount) * MemoryLayout<Float>.size)
            }
            if let rightData = buffers[1].mData {
                memcpy(rightData, inputRight.advanced(by: readOffset), copyFrames * MemoryLayout<Float>.size)
                if copyFrames < Int(frameCount) {
                    rightData.assumingMemoryBound(to: Float.self).advanced(by: copyFrames).initialize(repeating: 0, count: Int(frameCount) - copyFrames)
                }
                buffers[1].mDataByteSize = UInt32(Int(frameCount) * MemoryLayout<Float>.size)
            }

            readOffset += copyFrames
            return noErr
        }
    }

    private let engine: AVAudioEngine
    private let renderSourceState: RenderSourceState
    private let renderBuffer: AVAudioPCMBuffer
    private let maximumFrames: UInt32
    private let format: AVAudioFormat
    private let hostedStages: [HostedStage]

    init(stages: [InsertChainStage], sampleRate: Double, maximumFrames: UInt32) throws {
        guard !stages.isEmpty else {
            throw AudioEngineError.halConfigurationFailed("No insert stages were provided.")
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw AudioEngineError.halConfigurationFailed("Could not create the insert-chain stream format.")
        }
        guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else {
            throw AudioEngineError.halConfigurationFailed("Could not allocate the insert-chain render buffer.")
        }

        self.engine = AVAudioEngine()
        self.renderSourceState = RenderSourceState()
        self.renderBuffer = renderBuffer
        self.maximumFrames = maximumFrames
        self.format = format

        let sourceState = self.renderSourceState
        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            sourceState.render(frameCount: frameCount, audioBufferList: audioBufferList)
        }

        engine.attach(sourceNode)

        var previousNode: AVAudioNode = sourceNode
        var builtStages: [HostedStage] = []

        for stage in stages {
            guard let componentDescription = stage.processorPlugin.audioUnitComponentDescription else {
                throw AudioEngineError.halConfigurationFailed("Plug-in \(stage.assignedPlugin.name) is not an Audio Unit.")
            }

            let audioUnit = try Self.instantiateAudioUnit(componentDescription: componentDescription)
            engine.attach(audioUnit)
            engine.connect(previousNode, to: audioUnit, format: format)
            previousNode = audioUnit
            builtStages.append(HostedStage(stage: stage, audioUnit: audioUnit))
        }

        engine.connect(previousNode, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrames)
        try engine.start()

        self.hostedStages = builtStages
        self.renderBuffer.frameLength = maximumFrames
    }

    func process(
        frameCount: UInt32,
        sampleTime _: Double,
        inputLeft: UnsafeMutablePointer<Float>,
        inputRight: UnsafeMutablePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>
    ) -> OSStatus {
        guard frameCount > 0, frameCount <= maximumFrames else {
            return noErr
        }

        renderSourceState.currentInputLeft = inputLeft
        renderSourceState.currentInputRight = inputRight
        renderSourceState.currentFrameCount = Int(frameCount)
        renderSourceState.readOffset = 0
        renderBuffer.frameLength = frameCount

        do {
            let status = try engine.renderOffline(frameCount, to: renderBuffer)
            guard status == .success || status == .insufficientDataFromInputNode,
                  let channels = renderBuffer.floatChannelData,
                  renderBuffer.format.channelCount >= 2 else {
                return kAudio_ParamError
            }

            memcpy(outputLeft, channels[0], Int(frameCount) * MemoryLayout<Float>.size)
            memcpy(outputRight, channels[1], Int(frameCount) * MemoryLayout<Float>.size)
            return noErr
        } catch {
            return kAudio_ParamError
        }
    }

    func liveAudioUnit(for boxID: UUID) -> AVAudioUnit? {
        hostedStages.first(where: { $0.stage.boxID == boxID })?.audioUnit
    }

    func processorPlugin(for boxID: UUID) -> PluginDescriptor? {
        hostedStages.first(where: { $0.stage.boxID == boxID })?.stage.processorPlugin
    }

    func teardown() {
        engine.stop()
        engine.disableManualRenderingMode()
    }

    private static func instantiateAudioUnit(componentDescription: AudioComponentDescription) throws -> AVAudioUnit {
        final class Box: @unchecked Sendable {
            var audioUnit: AVAudioUnit?
            var error: Error?
        }

        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        AVAudioUnit.instantiate(with: componentDescription, options: []) { audioUnit, error in
            box.audioUnit = audioUnit
            box.error = error
            semaphore.signal()
        }

        semaphore.wait()

        if let error = box.error {
            throw error
        }
        guard let audioUnit = box.audioUnit else {
            throw AudioEngineError.halConfigurationFailed("Could not instantiate the Audio Unit.")
        }
        return audioUnit
    }
}

private extension PluginDescriptor {
    var audioUnitComponentDescription: AudioComponentDescription? {
        guard format == .audioUnit, id.hasPrefix("au:") else { return nil }
        let payload = String(id.dropFirst(3))
        let pieces = payload.split(separator: ".")
        guard pieces.count == 3,
              let type = OSType(pieces[0]),
              let subtype = OSType(pieces[1]),
              let manufacturer = OSType(pieces[2]) else {
            return nil
        }

        return AudioComponentDescription(
            componentType: type,
            componentSubType: subtype,
            componentManufacturer: manufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

private extension OSType {
    init?(_ text: Substring) {
        guard let value = UInt32(String(text)) else { return nil }
        self = value
    }
}
