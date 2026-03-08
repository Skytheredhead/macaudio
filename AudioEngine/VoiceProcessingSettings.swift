import Foundation

struct VoiceProcessingSettings: Codable, Equatable {
    var inputGainDB: Float = 0

    var eqEnabled: Bool = true
    var highPassEnabled: Bool = true
    var highPassHz: Float = 90

    var band1Enabled: Bool = true
    var band1FrequencyHz: Float = 160
    var band1GainDB: Float = 0
    var band1Q: Float = 0.9

    var band2Enabled: Bool = true
    var band2FrequencyHz: Float = 1800
    var band2GainDB: Float = 1.5
    var band2Q: Float = 1.0

    var band3Enabled: Bool = true
    var band3FrequencyHz: Float = 7200
    var band3GainDB: Float = 1
    var band3Q: Float = 0.8

    var compressorEnabled: Bool = true
    var compressorThresholdDB: Float = -20
    var compressorRatio: Float = 2.5
    var compressorAttackMs: Float = 8
    var compressorReleaseMs: Float = 140
    var makeupGainDB: Float = 1.5

    var limiterEnabled: Bool = true
    var limiterCeilingDB: Float = -1

    var outputGainDB: Float = 0

    var denoiseEnabled: Bool = false
    var denoiseStrength: Float = 0

    var gateEnabled: Bool = false
    var gateThresholdDB: Float = -50
    var gateAttackMs: Float = 10
    var gateReleaseMs: Float = 120
}

enum VoicePreset: String, CaseIterable, Identifiable {
    case cleanVoice = "Clean voice"
    case podcast = "Podcast"
    case broadcast = "Broadcast"
    case noisyRoom = "Noisy room"

    var id: String { "builtin:" + rawValue }

    var settings: VoiceProcessingSettings {
        switch self {
        case .cleanVoice:
            return VoiceProcessingSettings(
                inputGainDB: 0,
                eqEnabled: true,
                highPassEnabled: true,
                highPassHz: 90,
                band1Enabled: true,
                band1FrequencyHz: 150,
                band1GainDB: 0,
                band1Q: 0.9,
                band2Enabled: true,
                band2FrequencyHz: 1900,
                band2GainDB: 1.5,
                band2Q: 1.0,
                band3Enabled: true,
                band3FrequencyHz: 7600,
                band3GainDB: 1.0,
                band3Q: 0.8,
                compressorEnabled: true,
                compressorThresholdDB: -20,
                compressorRatio: 2.5,
                compressorAttackMs: 8,
                compressorReleaseMs: 140,
                makeupGainDB: 1.5,
                limiterEnabled: true,
                limiterCeilingDB: -1,
                outputGainDB: 0,
                denoiseEnabled: false,
                denoiseStrength: 0,
                gateEnabled: false,
                gateThresholdDB: -50,
                gateAttackMs: 10,
                gateReleaseMs: 120
            )
        case .podcast:
            return VoiceProcessingSettings(
                inputGainDB: 1,
                eqEnabled: true,
                highPassEnabled: true,
                highPassHz: 85,
                band1Enabled: true,
                band1FrequencyHz: 130,
                band1GainDB: 1,
                band1Q: 0.85,
                band2Enabled: true,
                band2FrequencyHz: 2400,
                band2GainDB: 2.2,
                band2Q: 1.1,
                band3Enabled: true,
                band3FrequencyHz: 9000,
                band3GainDB: 1.6,
                band3Q: 0.75,
                compressorEnabled: true,
                compressorThresholdDB: -24,
                compressorRatio: 3.2,
                compressorAttackMs: 6,
                compressorReleaseMs: 110,
                makeupGainDB: 3,
                limiterEnabled: true,
                limiterCeilingDB: -1,
                outputGainDB: 0,
                denoiseEnabled: false,
                denoiseStrength: 0,
                gateEnabled: false,
                gateThresholdDB: -48,
                gateAttackMs: 8,
                gateReleaseMs: 140
            )
        case .broadcast:
            return VoiceProcessingSettings(
                inputGainDB: 1.5,
                eqEnabled: true,
                highPassEnabled: true,
                highPassHz: 95,
                band1Enabled: true,
                band1FrequencyHz: 120,
                band1GainDB: 1.2,
                band1Q: 0.8,
                band2Enabled: true,
                band2FrequencyHz: 2800,
                band2GainDB: 2.5,
                band2Q: 1.2,
                band3Enabled: true,
                band3FrequencyHz: 9500,
                band3GainDB: 1.8,
                band3Q: 0.75,
                compressorEnabled: true,
                compressorThresholdDB: -26,
                compressorRatio: 4.0,
                compressorAttackMs: 4,
                compressorReleaseMs: 90,
                makeupGainDB: 4,
                limiterEnabled: true,
                limiterCeilingDB: -1.2,
                outputGainDB: 0,
                denoiseEnabled: false,
                denoiseStrength: 0,
                gateEnabled: true,
                gateThresholdDB: -42,
                gateAttackMs: 5,
                gateReleaseMs: 110
            )
        case .noisyRoom:
            return VoiceProcessingSettings(
                inputGainDB: 0,
                eqEnabled: true,
                highPassEnabled: true,
                highPassHz: 110,
                band1Enabled: true,
                band1FrequencyHz: 150,
                band1GainDB: -1,
                band1Q: 0.9,
                band2Enabled: true,
                band2FrequencyHz: 2200,
                band2GainDB: 1,
                band2Q: 1.0,
                band3Enabled: true,
                band3FrequencyHz: 6800,
                band3GainDB: 0.5,
                band3Q: 0.9,
                compressorEnabled: true,
                compressorThresholdDB: -18,
                compressorRatio: 3.5,
                compressorAttackMs: 8,
                compressorReleaseMs: 140,
                makeupGainDB: 3,
                limiterEnabled: true,
                limiterCeilingDB: -1,
                outputGainDB: 0,
                denoiseEnabled: false,
                denoiseStrength: 0,
                gateEnabled: true,
                gateThresholdDB: -40,
                gateAttackMs: 7,
                gateReleaseMs: 160
            )
        }
    }
}

struct UserPreset: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var settings: VoiceProcessingSettings
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
