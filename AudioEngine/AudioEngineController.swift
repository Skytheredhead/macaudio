import AudioToolbox
@preconcurrency import AVFoundation
import Combine
import CoreAudio
import Foundation
import QuartzCore

final class AudioEngineController: ObservableObject, @unchecked Sendable {
    private static let noInputFramesWarning = "No input frames from the selected microphone."
    private static let recoveringInputWarning = "Recovering microphone input..."
    private static let liveInsertWarningPrefix = "Some plug-ins could not be loaded into the live chain: "

    @Published var isRunning = false
    @Published var availableInputDevices: [AudioInputDevice] = []
    @Published var availableOutputDevices: [AudioOutputDevice] = []
    @Published var selectedInputDeviceID: AudioDeviceID = 0
    @Published var selectedOutputDeviceID: AudioDeviceID = 0
    @Published var selectedMonitorDeviceID: AudioDeviceID = 0
    @Published var selectedInputChannelMode: AudioChannelMode = .mono
    @Published var selectedOutputChannelMode: AudioChannelMode = .stereo
    @Published var rackWorkspaceMode: RackWorkspaceMode = .single
    @Published var dualMonoEndMode: DualMonoEndMode = .separate
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
    private let virtualMicRingName = "/macaudio-vm"
    private let routeRingName = "/macaudio-out"
    private let monitorRingName = "/macaudio-mon"
    private let hardwareObserverQueue = DispatchQueue(label: "com.skylarenns.macaudio.hardware", qos: .utility)
    private let controlQueue = DispatchQueue(label: "com.skylarenns.macaudio.control", qos: .userInitiated)
    private let controlQueueKey = DispatchSpecificKey<UInt8>()
    private let restartLock = NSLock()
    private let insertChainLock = NSLock()
    private let realtimeSnapshotLock = NSLock()

    private var dspChain: OpaquePointer?
    private var dspRightChain: OpaquePointer?
    private var inputUnit: AudioUnit?
    private var routeOutputUnit: AudioUnit?
    private var monitorOutputUnit: AudioUnit?

    private var routeWriter: OpaquePointer?
    private var routeReader: OpaquePointer?
    private var monitorWriter: OpaquePointer?
    private var monitorReader: OpaquePointer?
    private var virtualMicWriter: OpaquePointer?

    private var processScratch: UnsafeMutablePointer<Float>
    private var routeScratch: UnsafeMutablePointer<Float>
    private var monitorScratch: UnsafeMutablePointer<Float>
    private var stereoLeftScratch: UnsafeMutablePointer<Float>
    private var stereoRightScratch: UnsafeMutablePointer<Float>
    private var virtualMicScratch: UnsafeMutablePointer<Float>
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
    private var pendingMainInsertPlugins: [InsertChainStage] = []
    private var pendingLeftInsertPlugins: [InsertChainStage] = []
    private var pendingRightInsertPlugins: [InsertChainStage] = []
    private var pendingInsertSignature: [String] = []
    private var activeInsertSignature: [String] = []
    private var activeMainInsertChain: HostedAudioUnitInsertChain?
    private var activeLeftInsertChain: HostedAudioUnitInsertChain?
    private var activeRightInsertChain: HostedAudioUnitInsertChain?
    private var liveInsertLoadFailures: [String: String] = [:]
    private var pluginRenderSampleTime: Double = 0
    private var latestRealtimeSnapshot = RealtimeMeterSnapshot()
    private var activeInputChannelCount = 1
    private var activeOutputChannelMode: AudioChannelMode = .stereo
    private var activeRackWorkspaceMode: RackWorkspaceMode = .single
    private var activeDualMonoEndMode: DualMonoEndMode = .separate
    private var activeSampleRate: Double = 48_000
    private var activeBufferFrames: UInt32 = 128

    private var routeOutputContext: OutputRenderContext?
    private var monitorOutputContext: OutputRenderContext?
    private var restartGeneration: UInt64 = 0

    init() {
        processScratch = .allocate(capacity: maxFramesPerBuffer)
        routeScratch = .allocate(capacity: maxFramesPerBuffer * 2)
        monitorScratch = .allocate(capacity: maxFramesPerBuffer * 2)
        stereoLeftScratch = .allocate(capacity: maxFramesPerBuffer)
        stereoRightScratch = .allocate(capacity: maxFramesPerBuffer)
        virtualMicScratch = .allocate(capacity: maxFramesPerBuffer)
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
        virtualMicScratch.deallocate()
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

        let inputFallback = AudioDeviceCatalog.preferredInputDeviceID()
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
        updateInsertChains(main: plugins, left: [], right: [])
    }

    func updateInsertChains(main: [InsertChainStage], left: [InsertChainStage], right: [InsertChainStage]) {
        let signature = combinedInsertSignature(main: main, left: left, right: right)
        withInsertChainLock {
            pendingMainInsertPlugins = main
            pendingLeftInsertPlugins = left
            pendingRightInsertPlugins = right
            pendingInsertSignature = signature
        }
        guard isRunning || transportState == .starting else { return }
        guard signature != currentActiveInsertSignature() else { return }
        restartForConfigurationChange(message: "Updating insert chain...")
    }

    func liveAudioUnit(for boxID: UUID) -> AVAudioUnit? {
        withInsertChainLock {
            activeMainInsertChain?.liveAudioUnit(for: boxID)
                ?? activeLeftInsertChain?.liveAudioUnit(for: boxID)
                ?? activeRightInsertChain?.liveAudioUnit(for: boxID)
        }
    }

    func liveProcessorPlugin(for boxID: UUID) -> PluginDescriptor? {
        withInsertChainLock {
            activeMainInsertChain?.processorPlugin(for: boxID)
                ?? activeLeftInsertChain?.processorPlugin(for: boxID)
                ?? activeRightInsertChain?.processorPlugin(for: boxID)
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

    private func stopSynchronously(publishStopped: Bool = true) {
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
        if let chain = dspRightChain {
            dsp_chain_destroy(chain)
            dspRightChain = nil
        }
        releaseInsertChain()
        withInsertChainLock {
            activeInsertSignature = []
        }
        withRealtimeSnapshotLock {
            latestRealtimeSnapshot = RealtimeMeterSnapshot()
        }

        closeRing(&routeWriter)
        closeRing(&routeReader)
        closeRing(&monitorWriter)
        closeRing(&monitorReader)
        closeRing(&virtualMicWriter)

        publish {
            self.isRunning = false
            self.transportState = publishStopped ? .stopped : .starting
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
        guard isRunning || transportState == .starting else { return }
        restartForConfigurationChange(message: "Switching route output...")
    }

    func updateMonitorDevice(_ deviceID: AudioDeviceID) {
        selectedMonitorDeviceID = deviceID
        guard isRunning, monitorEnabled else { return }
        restartMonitorOutput(message: "Switching monitor output...")
    }

    func updateInputDevice(_ deviceID: AudioDeviceID) {
        if AudioDeviceCatalog.isMacAudioVirtualMic(deviceID) {
            selectedInputDeviceID = AudioDeviceCatalog.preferredInputDeviceID()
            warningMessage = "Choose a hardware microphone as input. Virtual Mic is the processed output for Discord."
        } else {
            selectedInputDeviceID = deviceID
        }
        guard isRunning || transportState == .starting else { return }
        restartForConfigurationChange(message: "Switching microphone...")
    }

    func updateIOConfiguration(sampleRate: SampleRateOption, bufferSize: BufferSizeOption) {
        selectedSampleRate = sampleRate
        selectedBufferSize = bufferSize
        guard isRunning || transportState == .starting else { return }
        restartForConfigurationChange(message: "Applying audio settings...")
    }

    func updateInputChannelMode(_ mode: AudioChannelMode) {
        selectedInputChannelMode = mode
        guard isRunning || transportState == .starting else { return }
        restartForConfigurationChange(message: "Switching input channel mode...")
    }

    func updateOutputChannelMode(_ mode: AudioChannelMode) {
        selectedOutputChannelMode = mode
        guard isRunning || transportState == .starting else { return }
        restartForConfigurationChange(message: "Switching output channel mode...")
    }

    func updateRackWorkspaceMode(_ mode: RackWorkspaceMode) {
        rackWorkspaceMode = mode
        guard isRunning || transportState == .starting else { return }
        restartForConfigurationChange(message: "Switching rack mode...")
    }

    func updateDualMonoEndMode(_ mode: DualMonoEndMode) {
        dualMonoEndMode = mode
        guard isRunning || transportState == .starting else { return }
        restartForConfigurationChange(message: "Switching dual mono output...")
    }

    func setMonitorEnabled(_ enabled: Bool) {
        monitorEnabled = enabled
        guard isRunning else { return }
        if enabled {
            restartMonitorOutput(message: "Enabling monitor...")
        } else {
            stopMonitorOutput(message: nil)
        }
    }

    private func startEngine(resetInputRecovery: Bool) {
        guard inputUnit == nil, routeOutputUnit == nil, dspChain == nil else {
            publish {
                self.isRunning = true
                self.transportState = .running
            }
            return
        }

        let startingState = syncOnMain {
            self.refreshInputDevices()
            return (
                selectedInput: self.selectedInputDeviceID,
                selectedOutput: self.selectedOutputDeviceID,
                selectedMonitor: self.selectedMonitorDeviceID,
                inputChannelMode: self.selectedInputChannelMode,
                outputChannelMode: self.selectedOutputChannelMode,
                rackWorkspaceMode: self.rackWorkspaceMode,
                dualMonoEndMode: self.dualMonoEndMode,
                monitorEnabled: self.monitorEnabled,
                sampleRate: self.selectedSampleRate,
                bufferSize: self.selectedBufferSize,
                latencyQuality: self.latencyQuality
            )
        }

        publish { self.warningMessage = nil }
        xrunAutoFallbackTriggered = false
        if resetInputRecovery {
            inputRecoveryAttempts = 0
        }
        withRealtimeSnapshotLock {
            latestRealtimeSnapshot = RealtimeMeterSnapshot()
        }

        let inputDeviceID = startingState.selectedInput == 0 ? AudioDeviceCatalog.preferredInputDeviceID() : startingState.selectedInput
        let outputDeviceID = startingState.selectedOutput == 0 ? AudioDeviceCatalog.preferredOutputDeviceID() : startingState.selectedOutput
        guard inputDeviceID != 0, outputDeviceID != 0 else {
            publish {
                self.warningMessage = "Connect an input and output device and retry."
                self.transportState = .stopped
            }
            return
        }

        let requestedInputChannels = startingState.inputChannelMode == .stereo || startingState.rackWorkspaceMode == .dualMono ? 2 : 1
        let availableInputChannels = max(1, AudioDeviceCatalog.inputChannelCount(deviceID: inputDeviceID))
        activeInputChannelCount = min(requestedInputChannels, availableInputChannels)
        activeOutputChannelMode = startingState.outputChannelMode
        activeRackWorkspaceMode = startingState.rackWorkspaceMode
        activeDualMonoEndMode = startingState.dualMonoEndMode
        if requestedInputChannels > activeInputChannelCount {
            publish { self.warningMessage = "Selected input is mono. Using the same signal for both dual mono racks." }
        }

        let bufferFrames = effectiveBufferFrames(sampleRateOption: startingState.sampleRate, bufferSizeOption: startingState.bufferSize, latencyQuality: startingState.latencyQuality)
        let sampleRate = resolveSampleRate(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID,
            requestedRate: startingState.sampleRate
        )
        activeSampleRate = sampleRate
        activeBufferFrames = bufferFrames
        configureDeviceIO(deviceID: inputDeviceID, sampleRate: sampleRate, frameSize: bufferFrames)
        configureDeviceIO(deviceID: outputDeviceID, sampleRate: sampleRate, frameSize: bufferFrames)
        if startingState.monitorEnabled, startingState.selectedMonitor != 0 {
            configureDeviceIO(deviceID: startingState.selectedMonitor, sampleRate: sampleRate, frameSize: bufferFrames)
        }

        setupRingBuffers(sampleRate: sampleRate)

        dspChain = dsp_chain_create(sampleRate, 1)
        dspRightChain = dsp_chain_create(sampleRate, 1)
        pushParametersToDSP()
        do {
            try buildInsertChain(sampleRate: sampleRate)
        } catch {
            publish { self.warningMessage = error.localizedDescription }
            releaseInsertChain()
            withInsertChainLock {
                activeInsertSignature = []
            }
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
        return AudioDeviceCatalog.nominalSampleRate(deviceID: inputDeviceID)
            ?? AudioDeviceCatalog.nominalSampleRate(deviceID: outputDeviceID)
            ?? 48_000
    }

    private func configureDeviceIO(deviceID: AudioDeviceID, sampleRate: Double, frameSize: UInt32) {
        _ = AudioDeviceCatalog.setNominalSampleRate(deviceID: deviceID, sampleRate: sampleRate)
        _ = AudioDeviceCatalog.setBufferFrameSize(deviceID: deviceID, frameSize: frameSize)
    }

    private func setupRingBuffers(sampleRate: Double) {
        _ = virtualMicRingName.withCString { vm_ring_unlink($0) }
        _ = routeRingName.withCString { vm_ring_unlink($0) }
        _ = monitorRingName.withCString { vm_ring_unlink($0) }

        closeRing(&virtualMicWriter)
        closeRing(&routeWriter)
        closeRing(&routeReader)
        closeRing(&monitorWriter)
        closeRing(&monitorReader)

        var virtualMicWriter: OpaquePointer?
        let virtualMicWriterResult = virtualMicRingName.withCString { vm_ring_create_writer($0, 8192, 1, &virtualMicWriter) }
        guard virtualMicWriterResult == 0, let virtualMicWriter else {
            publish { self.warningMessage = "Virtual Mic buffer failed (\(virtualMicWriterResult))." }
            return
        }
        vm_ring_set_sample_rate(virtualMicWriter, UInt32(sampleRate))
        self.virtualMicWriter = virtualMicWriter

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

        if activeInputChannelCount > 1 {
            if let chain = dspRightChain {
                dsp_chain_process_mono(chain, stereoRightScratch, UInt32(frameCount))
            }
            memcpy(stereoLeftScratch, processScratch, frameCount * MemoryLayout<Float>.size)
        } else {
            for frame in 0..<frameCount {
                let sample = processScratch[frame]
                stereoLeftScratch[frame] = sample
                stereoRightScratch[frame] = sample
            }
        }

        switch activeRackWorkspaceMode {
        case .single:
            processInsertChain(frameCount: UInt32(frameCount))
        case .dualMono:
            processDualMonoInsertChains(frameCount: UInt32(frameCount))
            if activeDualMonoEndMode == .merge {
                mergeStereoToDualMono(frameCount: frameCount)
            }
        }
        if activeOutputChannelMode == .mono {
            mergeStereoToDualMono(frameCount: frameCount)
        }
        interleaveStereo(frameCount: frameCount)
        mixVirtualMicMono(frameCount: frameCount)
        updateRealtimeSnapshot(frameCount: frameCount)

        if let virtualMicWriter {
            _ = vm_ring_write(virtualMicWriter, virtualMicScratch, UInt32(frameCount))
        }
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
            mChannelsPerFrame: UInt32(activeInputChannelCount),
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
            UnsafeMutableRawPointer(inputBufferListPointer).deallocate()
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
        if let inputBufferListPointer {
            UnsafeMutableRawPointer(inputBufferListPointer).deallocate()
            self.inputBufferListPointer = nil
        }
        let channelCount = max(1, min(activeInputChannelCount, 2))
        let byteCount = MemoryLayout<AudioBufferList>.size + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.stride
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        rawPointer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let pointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        pointer.pointee.mNumberBuffers = UInt32(channelCount)
        for index in 0..<channelCount {
            buffers[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(maxFramesPerBuffer * MemoryLayout<Float>.size),
                mData: index == 0 ? UnsafeMutableRawPointer(processScratch) : UnsafeMutableRawPointer(stereoRightScratch)
            )
        }
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
        if buffers.count > 1 {
            buffers[1].mData = UnsafeMutableRawPointer(stereoRightScratch)
            buffers[1].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        }

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
        if let rightChain = dspRightChain {
            dsp_chain_set_parameters(rightChain, params)
        }
    }

    private func buildInsertChain(sampleRate: Double) throws {
        releaseInsertChain()
        let pending = pendingInsertChainSnapshot()
        guard !pending.main.isEmpty || !pending.left.isEmpty || !pending.right.isEmpty else {
            withInsertChainLock {
                activeInsertSignature = []
            }
            liveInsertLoadFailures.removeAll()
            publishLiveInsertWarningIfNeeded()
            return
        }

        liveInsertLoadFailures.removeAll()
        let mainInsertChain = try buildInsertChain(for: pending.main, sampleRate: sampleRate)
        let leftInsertChain = try buildInsertChain(for: pending.left, sampleRate: sampleRate)
        let rightInsertChain = try buildInsertChain(for: pending.right, sampleRate: sampleRate)
        withInsertChainLock {
            activeMainInsertChain = mainInsertChain
            activeLeftInsertChain = leftInsertChain
            activeRightInsertChain = rightInsertChain
            activeInsertSignature = pending.signature
        }
        publishLiveInsertWarningIfNeeded()
    }

    private func buildInsertChain(for pendingPlugins: [InsertChainStage], sampleRate: Double) throws -> HostedAudioUnitInsertChain? {
        guard !pendingPlugins.isEmpty else { return nil }

        var insertStages: [InsertChainStage] = []
        for stage in pendingPlugins {
            if stage.processorPlugin.audioUnitComponentDescription != nil {
                insertStages.append(stage)
            } else {
                liveInsertLoadFailures[stage.processorPlugin.id] = "No loadable Audio Unit component was found."
            }
        }

        if !insertStages.isEmpty {
            let insertChain = try HostedAudioUnitInsertChain(
                stages: insertStages,
                sampleRate: sampleRate,
                maximumFrames: UInt32(maxFramesPerBuffer)
            )
            liveInsertLoadFailures.merge(insertChain.failedPluginMessages) { _, new in new }
            return insertChain.isEmpty ? nil : insertChain
        } else {
            return nil
        }
    }

    private func releaseInsertChain() {
        withInsertChainLock {
            activeMainInsertChain?.teardown()
            activeLeftInsertChain?.teardown()
            activeRightInsertChain?.teardown()
            activeMainInsertChain = nil
            activeLeftInsertChain = nil
            activeRightInsertChain = nil
        }
    }

    private func processInsertChain(frameCount: UInt32) {
        insertChainLock.lock()
        defer { insertChainLock.unlock() }
        guard let activeInsertChain = activeMainInsertChain else { return }

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

    private func processDualMonoInsertChains(frameCount: UInt32) {
        insertChainLock.lock()
        defer { insertChainLock.unlock() }
        if let activeLeftInsertChain {
            memcpy(insertInputLeftScratch, stereoLeftScratch, Int(frameCount) * MemoryLayout<Float>.size)
            memcpy(insertInputRightScratch, stereoLeftScratch, Int(frameCount) * MemoryLayout<Float>.size)
            let status = activeLeftInsertChain.process(
                frameCount: frameCount,
                sampleTime: pluginRenderSampleTime,
                inputLeft: insertInputLeftScratch,
                inputRight: insertInputRightScratch,
                outputLeft: stereoLeftScratch,
                outputRight: insertInputRightScratch
            )
            if status == noErr {
                averageMonoPair(left: stereoLeftScratch, right: insertInputRightScratch, output: stereoLeftScratch, frameCount: Int(frameCount))
            } else {
                memcpy(stereoLeftScratch, insertInputLeftScratch, Int(frameCount) * MemoryLayout<Float>.size)
            }
        }

        if let activeRightInsertChain {
            memcpy(insertInputLeftScratch, stereoRightScratch, Int(frameCount) * MemoryLayout<Float>.size)
            memcpy(insertInputRightScratch, stereoRightScratch, Int(frameCount) * MemoryLayout<Float>.size)
            let status = activeRightInsertChain.process(
                frameCount: frameCount,
                sampleTime: pluginRenderSampleTime,
                inputLeft: insertInputLeftScratch,
                inputRight: insertInputRightScratch,
                outputLeft: insertInputLeftScratch,
                outputRight: stereoRightScratch
            )
            if status == noErr {
                averageMonoPair(left: insertInputLeftScratch, right: stereoRightScratch, output: stereoRightScratch, frameCount: Int(frameCount))
            } else {
                memcpy(stereoRightScratch, insertInputRightScratch, Int(frameCount) * MemoryLayout<Float>.size)
            }
        }

        pluginRenderSampleTime += Double(frameCount)
    }

    private func mergeStereoToDualMono(frameCount: Int) {
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            let sample = (stereoLeftScratch[frame] + stereoRightScratch[frame]) * 0.5
            stereoLeftScratch[frame] = sample
            stereoRightScratch[frame] = sample
        }
    }

    private func averageMonoPair(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            output[frame] = (left[frame] + right[frame]) * 0.5
        }
    }

    private func interleaveStereo(frameCount: Int) {
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            interleavedStereoScratch[(frame * 2)] = stereoLeftScratch[frame]
            interleavedStereoScratch[(frame * 2) + 1] = stereoRightScratch[frame]
        }
    }

    private func mixVirtualMicMono(frameCount: Int) {
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            virtualMicScratch[frame] = (stereoLeftScratch[frame] + stereoRightScratch[frame]) * 0.5
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
        let shouldRestart = isRunning || transportState == .starting
        guard shouldRestart else { return }

        let generation = nextRestartGeneration()
        publish { self.transportState = .starting }
        controlQueue.async { [weak self] in
            guard let self, self.isRestartCurrent(generation) else { return }
            self.stopSynchronously(publishStopped: false)
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
            self.stopSynchronously(publishStopped: false)
            guard self.isRestartCurrent(generation) else { return }
            self.startEngine(resetInputRecovery: false)
        }
    }

    private func restartMonitorOutput(message: String? = nil) {
        suppressInputWatchdog(for: 1.0)
        warningMessage = message

        let deviceID = selectedMonitorDeviceID
        let sampleRate = activeSampleRate
        let bufferFrames = activeBufferFrames
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.stopOutputUnit(&self.monitorOutputUnit)
            self.monitorOutputContext = nil

            guard deviceID != 0 else {
                self.publish {
                    self.monitorEnabled = false
                    self.warningMessage = "Choose a monitor output device."
                }
                return
            }

            self.configureDeviceIO(deviceID: deviceID, sampleRate: sampleRate, frameSize: bufferFrames)
            do {
                try self.setupOutputUnit(deviceID: deviceID, sampleRate: sampleRate, kind: .monitor)
                guard let monitorOutputUnit = self.monitorOutputUnit,
                      AudioOutputUnitStart(monitorOutputUnit) == noErr else {
                    throw AudioEngineError.halConfigurationFailed("Could not start monitor output.")
                }
                self.publish {
                    if self.warningMessage == message {
                        self.warningMessage = nil
                    }
                }
            } catch {
                self.stopOutputUnit(&self.monitorOutputUnit)
                self.monitorOutputContext = nil
                self.publish {
                    self.monitorEnabled = false
                    self.warningMessage = error.localizedDescription
                }
            }
        }
    }

    private func stopMonitorOutput(message: String?) {
        warningMessage = message
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.stopOutputUnit(&self.monitorOutputUnit)
            self.monitorOutputContext = nil
            if let message {
                self.publish {
                    if self.warningMessage == message {
                        self.warningMessage = nil
                    }
                }
            }
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

    private func combinedInsertSignature(
        main: [InsertChainStage],
        left: [InsertChainStage],
        right: [InsertChainStage]
    ) -> [String] {
        insertSignature(for: main).map { "main|\($0)" }
            + insertSignature(for: left).map { "left|\($0)" }
            + insertSignature(for: right).map { "right|\($0)" }
    }

    private func pendingInsertChainSnapshot() -> (main: [InsertChainStage], left: [InsertChainStage], right: [InsertChainStage], signature: [String]) {
        withInsertChainLock {
            (
                pendingMainInsertPlugins,
                pendingLeftInsertPlugins,
                pendingRightInsertPlugins,
                pendingInsertSignature
            )
        }
    }

    private func currentActiveInsertSignature() -> [String] {
        withInsertChainLock {
            activeInsertSignature
        }
    }

    private func publishLiveInsertWarningIfNeeded() {
        var seenPluginIDs = Set<String>()
        let pending = pendingInsertChainSnapshot()
        let failureSummaries = (pending.main + pending.left + pending.right).compactMap { stage -> String? in
            guard let failure = liveInsertLoadFailures[stage.processorPlugin.id],
                  seenPluginIDs.insert(stage.processorPlugin.id).inserted else {
                return nil
            }
            return "\(stage.assignedPlugin.name) (\(failure))"
        }

        publish {
            if failureSummaries.isEmpty {
                if self.warningMessage?.hasPrefix(Self.liveInsertWarningPrefix) == true {
                    self.warningMessage = nil
                }
            } else {
                self.warningMessage = Self.liveInsertWarningPrefix + failureSummaries.joined(separator: ", ")
            }
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

    @discardableResult
    private func withInsertChainLock<T>(_ block: () -> T) -> T {
        insertChainLock.lock()
        defer { insertChainLock.unlock() }
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
    private static let audioUnitInstantiationTimeoutSeconds = 30.0

    private struct HostedStage {
        let stage: InsertChainStage
        let audioUnit: AVAudioUnit
    }

    private enum AudioUnitLoadError: LocalizedError {
        case timedOut(String, TimeInterval)

        var errorDescription: String? {
            switch self {
            case .timedOut(let pluginName, let timeoutSeconds):
                return "Plug-in load timed out after \(Int(timeoutSeconds)) seconds: \(pluginName)"
            }
        }
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
    let failedPluginMessages: [String: String]

    var isEmpty: Bool {
        hostedStages.isEmpty
    }

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
        var failedPluginMessages: [String: String] = [:]

        for stage in stages {
            guard let componentDescription = stage.processorPlugin.audioUnitComponentDescription else {
                failedPluginMessages[stage.processorPlugin.id] = "No loadable Audio Unit component was found."
                continue
            }

            do {
                let audioUnit = try Self.instantiateAudioUnit(
                    componentDescription: componentDescription,
                    pluginName: stage.assignedPlugin.name
                )
                engine.attach(audioUnit)
                engine.connect(previousNode, to: audioUnit, format: format)
                previousNode = audioUnit
                builtStages.append(HostedStage(stage: stage, audioUnit: audioUnit))
            } catch {
                failedPluginMessages[stage.processorPlugin.id] = Self.failureDescription(for: error)
            }
        }

        if !builtStages.isEmpty {
            engine.connect(previousNode, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrames)
            try engine.start()
        }

        self.hostedStages = builtStages
        self.failedPluginMessages = failedPluginMessages
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

    private static func instantiateAudioUnit(
        componentDescription: AudioComponentDescription,
        pluginName: String,
        timeoutSeconds: TimeInterval = audioUnitInstantiationTimeoutSeconds
    ) throws -> AVAudioUnit {
        final class Box: @unchecked Sendable {
            var audioUnit: AVAudioUnit?
            var error: Error?
        }

        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let instantiate: @Sendable () -> Void = {
            AVAudioUnit.instantiate(with: componentDescription, options: []) { audioUnit, error in
                box.audioUnit = audioUnit
                box.error = error
                semaphore.signal()
            }
        }

        if Thread.isMainThread {
            instantiate()
        } else {
            DispatchQueue.main.async(execute: instantiate)
        }

        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw AudioUnitLoadError.timedOut(pluginName, timeoutSeconds)
        }

        if let error = box.error {
            throw error
        }
        guard let audioUnit = box.audioUnit else {
            throw AudioEngineError.halConfigurationFailed("Could not instantiate the Audio Unit.")
        }
        return audioUnit
    }

    private static func failureDescription(for error: Error) -> String {
        let nsError = error as NSError
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty,
           description != "The operation couldn’t be completed. (\(nsError.domain) error \(nsError.code).)" {
            return description
        }
        return "\(nsError.domain) \(nsError.code)"
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
