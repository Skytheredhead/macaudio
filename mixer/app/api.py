from __future__ import annotations

from dataclasses import asdict
from pathlib import Path
from typing import Any, Dict, List

from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .audio import AudioEngine
from .state import CompressorSettings, DeviceSelection, EqSettings, MixerParams, SharedState


def create_app(state: SharedState, audio: AudioEngine) -> FastAPI:
    app = FastAPI()
    ui_path = Path(__file__).resolve().parents[1] / "ui"

    app.mount("/ui", StaticFiles(directory=str(ui_path)), name="ui")

    @app.get("/")
    def index() -> FileResponse:
        return FileResponse(str(ui_path / "index.html"))

    @app.get("/devices")
    def list_devices() -> List[Dict[str, Any]]:
        return [device.__dict__ for device in audio.list_devices()]

    @app.get("/state")
    def get_state() -> Dict[str, Any]:
        params = state.params
        devices = state.devices
        return {
            "params": {
                "gain_db": params.gain_db,
                "compressor": asdict(params.compressor),
                "eq": asdict(params.eq),
            },
            "devices": asdict(devices),
        }

    @app.post("/state")
    def update_state(payload: Dict[str, Any]) -> Dict[str, Any]:
        params = state.params
        compressor = payload.get("compressor", {})
        eq = payload.get("eq", {})
        new_params = MixerParams(
            gain_db=float(payload.get("gain_db", params.gain_db)),
            compressor=CompressorSettings(
                threshold_db=float(
                    compressor.get("threshold_db", params.compressor.threshold_db)
                ),
                ratio=float(compressor.get("ratio", params.compressor.ratio)),
                attack_ms=float(
                    compressor.get("attack_ms", params.compressor.attack_ms)
                ),
                release_ms=float(
                    compressor.get("release_ms", params.compressor.release_ms)
                ),
            ),
            eq=EqSettings(
                frequency=float(eq.get("frequency", params.eq.frequency)),
                gain_db=float(eq.get("gain_db", params.eq.gain_db)),
                q=float(eq.get("q", params.eq.q)),
            ),
        )
        state.update_params(new_params)
        return {"status": "ok"}

    @app.post("/devices/select")
    def select_devices(payload: Dict[str, Any]) -> Dict[str, Any]:
        devices = state.devices
        new_devices = DeviceSelection(
            input_device=payload.get("input_device", devices.input_device),
            output_device=payload.get("output_device", devices.output_device),
        )
        state.update_devices(new_devices)
        return {"status": "ok"}

    return app
