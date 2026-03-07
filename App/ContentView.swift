import CoreAudio
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        ZStack {
            AppTheme.background

            VStack(spacing: 16) {
                HeaderPanel(
                    engine: viewModel.engine,
                    accentOrange: accentOrange,
                    onToggleRun: viewModel.toggleRunState
                )

                HStack(alignment: .top, spacing: 16) {
                    RoutingPanel(
                        engine: viewModel.engine,
                        selectedPreset: $viewModel.selectedPreset,
                        accentOrange: accentOrange,
                        onRefreshDevices: viewModel.refreshDevices,
                        onInputChange: viewModel.updateInputDevice,
                        onOutputChange: viewModel.updateMonitorDevice,
                        onIOConfigChange: viewModel.updateIOConfiguration,
                        onLatencyChange: viewModel.applyLatencyQuality
                    )
                    .frame(width: 320)

                    VStack(spacing: 16) {
                        LevelsPanel(engine: viewModel.engine)
                        ProcessingPanel(settings: $viewModel.settings, accentOrange: accentOrange)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 1080, minHeight: 720)
        .onAppear {
            viewModel.refreshDevices()
        }
    }

    private var isWindowActive: Bool {
        controlActiveState == .key || controlActiveState == .active
    }

    private var accentOrange: Color {
        isWindowActive
            ? Color(red: 0.95, green: 0.66, blue: 0.35)
            : Color(red: 0.74, green: 0.60, blue: 0.44)
    }
}

private struct HeaderPanel: View {
    @ObservedObject var engine: AudioEngineController
    let accentOrange: Color
    let onToggleRun: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MacAudio")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 10) {
                    AppTheme.statusBadge(engine.isRunning ? "Running" : "Stopped", tint: engine.isRunning ? Color.green : Color.gray)
                    AppTheme.statusBadge(engine.routeStatus, tint: Color.cyan)
                }
            }

            Spacer()

            Button(engine.isRunning ? "Stop" : "Start") {
                onToggleRun()
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule().fill(accentOrange))
        }
        .padding(20)
        .background(AppTheme.cardBackground)
    }
}

private struct RoutingPanel: View {
    @ObservedObject var engine: AudioEngineController
    @Binding var selectedPreset: VoicePreset
    let accentOrange: Color
    let onRefreshDevices: () -> Void
    let onInputChange: () -> Void
    let onOutputChange: () -> Void
    let onIOConfigChange: () -> Void
    let onLatencyChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                AppTheme.panelTitle("Routing")
                Spacer()
                Button("Refresh") {
                    onRefreshDevices()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                )
            }

            AppTheme.menuField("Input", selection: inputBinding) {
                ForEach(engine.availableInputDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }

            AppTheme.menuField("Output", selection: outputBinding) {
                ForEach(engine.availableOutputDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }

            AppTheme.menuField("Preset", selection: $selectedPreset) {
                ForEach(VoicePreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }

            HStack(spacing: 12) {
                AppTheme.menuField("Rate", selection: sampleRateBinding) {
                    ForEach(SampleRateOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }

                AppTheme.menuField("Buffer", selection: bufferBinding) {
                    ForEach(BufferSizeOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            }

            AppTheme.sliderField(
                "Latency",
                value: latencyBinding,
                range: 0...1,
                valueText: engine.selectedBufferSize.rawValue,
                tint: accentOrange
            )

            AppTheme.sliderField(
                "Output Level",
                value: outputLevelBinding,
                range: 0...1,
                valueText: "\(Int(engine.monitorLevel * 100))%",
                tint: Color.cyan
            )

            if let warning = engine.warningMessage, !warning.isEmpty {
                Text(warning)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(accentOrange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(18)
        .background(AppTheme.cardBackground)
    }

    private var inputBinding: Binding<AudioDeviceID> {
        Binding(
            get: { engine.selectedInputDeviceID },
            set: {
                engine.selectedInputDeviceID = $0
                onInputChange()
            }
        )
    }

    private var outputBinding: Binding<AudioDeviceID> {
        Binding(
            get: { engine.selectedMonitorDeviceID },
            set: {
                engine.selectedMonitorDeviceID = $0
                onOutputChange()
            }
        )
    }

    private var sampleRateBinding: Binding<SampleRateOption> {
        Binding(
            get: { engine.selectedSampleRate },
            set: {
                engine.selectedSampleRate = $0
                onIOConfigChange()
            }
        )
    }

    private var bufferBinding: Binding<BufferSizeOption> {
        Binding(
            get: { engine.selectedBufferSize },
            set: {
                engine.selectedBufferSize = $0
                onIOConfigChange()
            }
        )
    }

    private var latencyBinding: Binding<Float> {
        Binding(
            get: { engine.latencyQuality },
            set: {
                engine.latencyQuality = $0
                onLatencyChange()
            }
        )
    }

    private var outputLevelBinding: Binding<Float> {
        Binding(
            get: { engine.monitorLevel },
            set: { engine.monitorLevel = $0 }
        )
    }
}

private struct LevelsPanel: View {
    @ObservedObject var engine: AudioEngineController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppTheme.panelTitle("Levels")

            AppTheme.meterRow("Input", value: engine.inputPeak, tint: Color.green)
            AppTheme.meterRow("Output", value: engine.outputPeak, tint: Color.cyan)

            HStack(spacing: 12) {
                AppTheme.metricBox("Over", "\(engine.xrunsOverruns)")
                AppTheme.metricBox("Under", "\(engine.xrunsUnderruns)")
                AppTheme.metricBox("Clip", "\(engine.clippedSamples)")
                AppTheme.metricBox("GR", String(format: "%.1f dB", engine.gainReductionDB))
            }
        }
        .padding(18)
        .background(AppTheme.cardBackground)
    }
}

private struct ProcessingPanel: View {
    @Binding var settings: VoiceProcessingSettings
    let accentOrange: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppTheme.panelTitle("Processing")

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    AppTheme.compactSection("EQ") {
                        AppTheme.sliderField("Input", value: $settings.inputGainDB, range: -12...24, valueText: AppTheme.dbString(settings.inputGainDB), tint: accentOrange)
                        AppTheme.sliderField("HPF", value: $settings.hpfHz, range: 60...180, valueText: AppTheme.hzString(settings.hpfHz), tint: accentOrange)
                        AppTheme.sliderField("Low", value: $settings.lowGainDB, range: -12...12, valueText: AppTheme.dbString(settings.lowGainDB), tint: accentOrange)
                        AppTheme.sliderField("Mid", value: $settings.midGainDB, range: -12...12, valueText: AppTheme.dbString(settings.midGainDB), tint: accentOrange)
                        AppTheme.sliderField("High", value: $settings.highGainDB, range: -12...12, valueText: AppTheme.dbString(settings.highGainDB), tint: accentOrange)
                    }
                }

                VStack(spacing: 12) {
                    AppTheme.compactSection("Dynamics") {
                        AppTheme.sliderField("Threshold", value: $settings.compressorThresholdDB, range: -48 ... -6, valueText: AppTheme.dbString(settings.compressorThresholdDB), tint: accentOrange)
                        AppTheme.sliderField("Ratio", value: $settings.compressorRatio, range: 1...8, valueText: String(format: "%.1f:1", settings.compressorRatio), tint: accentOrange)
                        AppTheme.sliderField("Attack", value: $settings.compressorAttackMs, range: 1...40, valueText: AppTheme.msString(settings.compressorAttackMs), tint: accentOrange)
                        AppTheme.sliderField("Release", value: $settings.compressorReleaseMs, range: 40...250, valueText: AppTheme.msString(settings.compressorReleaseMs), tint: accentOrange)
                        AppTheme.sliderField("Output", value: $settings.outputGainDB, range: -12...12, valueText: AppTheme.dbString(settings.outputGainDB), tint: accentOrange)
                    }
                }
            }

            AppTheme.compactSection("Cleanup") {
                AppTheme.toggleRow("Denoise", isOn: $settings.denoiseEnabled)
                AppTheme.sliderField("Denoise Amt", value: $settings.denoiseStrength, range: 0...1, valueText: "\(Int(settings.denoiseStrength * 100))%", tint: Color.cyan)
                AppTheme.toggleRow("Gate", isOn: $settings.gateEnabled)
                AppTheme.toggleRow("De-esser", isOn: $settings.deEsserEnabled)
            }
        }
        .padding(18)
        .background(AppTheme.cardBackground)
    }
}

private enum AppTheme {
    static var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.08, blue: 0.11),
                Color(red: 0.08, green: 0.10, blue: 0.14)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    static var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(red: 0.12, green: 0.14, blue: 0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    static func panelTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
    }

    static func statusBadge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tint.opacity(0.22))
            )
    }

    static func menuField<SelectionValue: Hashable, Content: View>(
        _ title: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.62))

            Picker(title, selection: selection) {
                content()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
    }

    static func sliderField(
        _ title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        valueText: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.86))
            }

            Slider(value: value, in: range)
                .tint(tint)
        }
    }

    @MainActor
    static func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .toggleStyle(.switch)
    }

    static func compactSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.62))

            VStack(spacing: 10) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    static func meterRow(_ title: String, value: Float, tint: Color) -> some View {
        let dbValue = linearToDisplayDB(value)
        let meterFill = meterNormalized(value)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(dbValue)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.86))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(8, geometry.size.width * CGFloat(meterFill)))
                }
            }
            .frame(height: 10)
        }
    }

    static func metricBox(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.62))
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    static func dbString(_ value: Float) -> String {
        String(format: "%.1f dB", value)
    }

    static func hzString(_ value: Float) -> String {
        String(format: "%.0f Hz", value)
    }

    static func msString(_ value: Float) -> String {
        String(format: "%.1f ms", value)
    }

    static func linearToDisplayDB(_ value: Float) -> String {
        guard value > 0.000_001 else {
            return "-inf"
        }
        let db = 20.0 * log10(Double(value))
        return String(format: "%.0f dB", db)
    }

    static func meterNormalized(_ value: Float) -> Double {
        guard value > 0.000_001 else {
            return 0.0
        }
        let db = max(-60.0, min(0.0, 20.0 * log10(Double(value))))
        return (db + 60.0) / 60.0
    }
}

#Preview {
    ContentView()
}
