from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class EqSettings:
    frequency: float = 1000.0
    gain_db: float = 0.0
    q: float = 1.0


@dataclass(frozen=True)
class CompressorSettings:
    threshold_db: float = -18.0
    ratio: float = 2.0
    attack_ms: float = 10.0
    release_ms: float = 100.0


@dataclass(frozen=True)
class MixerParams:
    gain_db: float = 0.0
    compressor: CompressorSettings = CompressorSettings()
    eq: EqSettings = EqSettings()


@dataclass(frozen=True)
class DeviceSelection:
    input_device: Optional[int] = None
    output_device: Optional[int] = None


class SharedState:
    def __init__(self) -> None:
        self._params: MixerParams = MixerParams()
        self._devices: DeviceSelection = DeviceSelection()
        self._device_change_token: int = 0

    @property
    def params(self) -> MixerParams:
        return self._params

    def update_params(self, params: MixerParams) -> None:
        self._params = params

    @property
    def devices(self) -> DeviceSelection:
        return self._devices

    def update_devices(self, devices: DeviceSelection) -> None:
        self._devices = devices
        self._device_change_token += 1

    @property
    def device_change_token(self) -> int:
        return self._device_change_token
