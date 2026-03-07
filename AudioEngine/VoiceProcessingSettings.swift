import Foundation

struct VoiceProcessingSettings: Equatable {
    var inputGainDB: Float = 0
    var hpfHz: Float = 90
    var lowGainDB: Float = 0
    var midGainDB: Float = 0
    var highGainDB: Float = 0

    var compressorThresholdDB: Float = -18
    var compressorRatio: Float = 3
    var compressorAttackMs: Float = 8
    var compressorReleaseMs: Float = 120
    var makeupGainDB: Float = 2
    var limiterCeilingDB: Float = -1
    var outputGainDB: Float = 0

    var denoiseEnabled: Bool = true
    var denoiseStrength: Float = 0.25

    var gateEnabled: Bool = false
    var gateThresholdDB: Float = -45

    var deEsserEnabled: Bool = false
    var deEsserAmount: Float = 0
}

enum VoicePreset: String, CaseIterable, Identifiable {
    case cleanVoice = "Clean voice"
    case podcast = "Podcast"
    case broadcast = "Broadcast"
    case noisyRoom = "Noisy room"

    var id: String { rawValue }

    var settings: VoiceProcessingSettings {
        switch self {
        case .cleanVoice:
            return VoiceProcessingSettings(
                inputGainDB: 0,
                hpfHz: 90,
                lowGainDB: 0,
                midGainDB: 1.5,
                highGainDB: 1,
                compressorThresholdDB: -20,
                compressorRatio: 2.5,
                compressorAttackMs: 8,
                compressorReleaseMs: 140,
                makeupGainDB: 1.5,
                limiterCeilingDB: -1,
                outputGainDB: 0,
                denoiseEnabled: true,
                denoiseStrength: 0.2,
                gateEnabled: false,
                gateThresholdDB: -50,
                deEsserEnabled: false,
                deEsserAmount: 0
            )
        case .podcast:
            return VoiceProcessingSettings(
                inputGainDB: 1,
                hpfHz: 85,
                lowGainDB: 1,
                midGainDB: 2,
                highGainDB: 1.5,
                compressorThresholdDB: -24,
                compressorRatio: 3.2,
                compressorAttackMs: 6,
                compressorReleaseMs: 110,
                makeupGainDB: 3,
                limiterCeilingDB: -1,
                outputGainDB: 0,
                denoiseEnabled: true,
                denoiseStrength: 0.28,
                gateEnabled: false,
                gateThresholdDB: -48,
                deEsserEnabled: true,
                deEsserAmount: 0.3
            )
        case .broadcast:
            return VoiceProcessingSettings(
                inputGainDB: 1.5,
                hpfHz: 95,
                lowGainDB: 1.2,
                midGainDB: 2.2,
                highGainDB: 1.8,
                compressorThresholdDB: -26,
                compressorRatio: 4.0,
                compressorAttackMs: 4,
                compressorReleaseMs: 90,
                makeupGainDB: 4,
                limiterCeilingDB: -1.2,
                outputGainDB: 0,
                denoiseEnabled: true,
                denoiseStrength: 0.35,
                gateEnabled: true,
                gateThresholdDB: -42,
                deEsserEnabled: true,
                deEsserAmount: 0.45
            )
        case .noisyRoom:
            return VoiceProcessingSettings(
                inputGainDB: 0,
                hpfHz: 110,
                lowGainDB: -1,
                midGainDB: 1,
                highGainDB: 0.5,
                compressorThresholdDB: -18,
                compressorRatio: 3.5,
                compressorAttackMs: 8,
                compressorReleaseMs: 140,
                makeupGainDB: 3,
                limiterCeilingDB: -1,
                outputGainDB: 0,
                denoiseEnabled: true,
                denoiseStrength: 0.55,
                gateEnabled: true,
                gateThresholdDB: -40,
                deEsserEnabled: false,
                deEsserAmount: 0
            )
        }
    }
}

enum SampleRateOption: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case hz48k = "48 kHz"
    case hz44k1 = "44.1 kHz"

    var id: String { rawValue }

    var sampleRate: Double? {
        switch self {
        case .auto:
            return nil
        case .hz48k:
            return 48_000
        case .hz44k1:
            return 44_100
        }
    }
}

enum BufferSizeOption: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case f64 = "64"
    case f128 = "128"
    case f256 = "256"

    var id: String { rawValue }

    var frames: UInt32? {
        switch self {
        case .auto:
            return nil
        case .f64:
            return 64
        case .f128:
            return 128
        case .f256:
            return 256
        }
    }
}
