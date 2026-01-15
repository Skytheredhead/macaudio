from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from scipy import signal

from .state import CompressorSettings, EqSettings


@dataclass
class Biquad:
    b0: float = 1.0
    b1: float = 0.0
    b2: float = 0.0
    a1: float = 0.0
    a2: float = 0.0
    z1: float = 0.0
    z2: float = 0.0

    def reset(self) -> None:
        self.z1 = 0.0
        self.z2 = 0.0

    def set_peaking(self, sample_rate: float, settings: EqSettings) -> None:
        freq = max(10.0, min(settings.frequency, sample_rate * 0.45))
        q = max(0.1, settings.q)
        gain_linear = 10 ** (settings.gain_db / 40.0)
        omega = 2.0 * math.pi * freq / sample_rate
        sin_omega = math.sin(omega)
        cos_omega = math.cos(omega)
        alpha = sin_omega / (2.0 * q)

        b0 = 1.0 + alpha * gain_linear
        b1 = -2.0 * cos_omega
        b2 = 1.0 - alpha * gain_linear
        a0 = 1.0 + alpha / gain_linear
        a1 = -2.0 * cos_omega
        a2 = 1.0 - alpha / gain_linear

        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0

    def process(self, samples: np.ndarray) -> np.ndarray:
        b = np.array([self.b0, self.b1, self.b2], dtype=np.float32)
        a = np.array([1.0, self.a1, self.a2], dtype=np.float32)
        zi = np.array([self.z1, self.z2], dtype=np.float32)
        out, zf = signal.lfilter(b, a, samples, zi=zi)
        self.z1 = float(zf[0])
        self.z2 = float(zf[1])
        return out


@dataclass
class Compressor:
    envelope: float = 0.0

    def process(
        self,
        samples: np.ndarray,
        settings: CompressorSettings,
        sample_rate: float,
    ) -> np.ndarray:
        threshold_db = settings.threshold_db
        ratio = max(1.0, settings.ratio)
        attack_coeff = math.exp(-1.0 / (0.001 * settings.attack_ms * sample_rate))
        release_coeff = math.exp(-1.0 / (0.001 * settings.release_ms * sample_rate))

        out = np.empty_like(samples)
        env = self.envelope
        for idx, x in enumerate(samples):
            level = abs(x)
            if level > env:
                env = attack_coeff * env + (1.0 - attack_coeff) * level
            else:
                env = release_coeff * env + (1.0 - release_coeff) * level

            env_db = 20.0 * math.log10(env + 1e-9)
            if env_db > threshold_db:
                gain_db = threshold_db + (env_db - threshold_db) / ratio - env_db
            else:
                gain_db = 0.0
            gain = 10 ** (gain_db / 20.0)
            out[idx] = x * gain
        self.envelope = env
        return out
