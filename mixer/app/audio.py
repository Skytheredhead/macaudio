from __future__ import annotations

import threading
from dataclasses import dataclass
from typing import List, Optional

import numpy as np
import sounddevice as sd

from .dsp import Biquad, Compressor
from .state import DeviceSelection, MixerParams, SharedState


@dataclass
class DeviceInfo:
    id: int
    name: str
    max_input_channels: int
    max_output_channels: int
    default_samplerate: float


class AudioEngine:
    def __init__(self, state: SharedState, block_size: int = 512) -> None:
        self._state = state
        self._block_size = block_size
        self._stream: Optional[sd.Stream] = None
        self._thread_lock = threading.Lock()
        self._biquads: List[Biquad] = []
        self._compressors: List[Compressor] = []
        self._sample_rate: float = 48000.0
        self._last_device_token = state.device_change_token

    def list_devices(self) -> List[DeviceInfo]:
        devices = []
        for idx, device in enumerate(sd.query_devices()):
            devices.append(
                DeviceInfo(
                    id=idx,
                    name=device["name"],
                    max_input_channels=device["max_input_channels"],
                    max_output_channels=device["max_output_channels"],
                    default_samplerate=device["default_samplerate"],
                )
            )
        return devices

    def start(self) -> None:
        self._start_stream(self._state.devices)

    def stop(self) -> None:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

    def poll_device_changes(self) -> None:
        token = self._state.device_change_token
        if token != self._last_device_token:
            self._last_device_token = token
            self._restart_stream(self._state.devices)

    def _restart_stream(self, devices: DeviceSelection) -> None:
        with self._thread_lock:
            self.stop()
            self._start_stream(devices)

    def _start_stream(self, devices: DeviceSelection) -> None:
        device_tuple = (devices.input_device, devices.output_device)
        input_device_info = None
        output_device_info = None
        if devices.input_device is not None:
            input_device_info = sd.query_devices(devices.input_device)
        if devices.output_device is not None:
            output_device_info = sd.query_devices(devices.output_device)

        sample_rate = None
        if input_device_info is not None:
            sample_rate = input_device_info["default_samplerate"]
        if output_device_info is not None:
            sample_rate = output_device_info["default_samplerate"]
        if sample_rate is None:
            sample_rate = sd.query_devices(None, "output")["default_samplerate"]

        self._sample_rate = float(sample_rate)

        channels_in = input_device_info["max_input_channels"] if input_device_info else 1
        channels_out = (
            output_device_info["max_output_channels"] if output_device_info else 2
        )
        channels = max(1, min(channels_in, channels_out))

        self._biquads = [Biquad() for _ in range(channels)]
        self._compressors = [Compressor() for _ in range(channels)]

        self._stream = sd.Stream(
            device=device_tuple,
            channels=channels,
            callback=self._callback,
            blocksize=self._block_size,
            samplerate=self._sample_rate,
        )
        self._stream.start()

    def _callback(
        self,
        indata: np.ndarray,
        outdata: np.ndarray,
        frames: int,
        time: sd.CallbackFlags,
        status: sd.CallbackFlags,
    ) -> None:
        params: MixerParams = self._state.params
        gain = 10 ** (params.gain_db / 20.0)

        for channel in range(outdata.shape[1]):
            channel_in = indata[:, channel]
            channel_out = channel_in * gain
            channel_out = self._compressors[channel].process(
                channel_out, params.compressor, self._sample_rate
            )
            biquad = self._biquads[channel]
            biquad.set_peaking(self._sample_rate, params.eq)
            channel_out = biquad.process(channel_out)
            outdata[:, channel] = channel_out

        if outdata.shape[1] > indata.shape[1]:
            outdata[:, indata.shape[1] :] = 0.0
