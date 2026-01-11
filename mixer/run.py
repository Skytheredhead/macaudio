from __future__ import annotations

import threading
import time
import webbrowser

import uvicorn

from app.api import create_app
from app.audio import AudioEngine
from app.state import SharedState


def start_server(state: SharedState, audio: AudioEngine) -> uvicorn.Server:
    app = create_app(state, audio)
    config = uvicorn.Config(app=app, host="127.0.0.1", port=8000, log_level="info")
    server = uvicorn.Server(config)

    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    return server


def main() -> None:
    state = SharedState()
    audio = AudioEngine(state)
    audio.start()

    server = start_server(state, audio)
    webbrowser.open("http://127.0.0.1:8000")

    try:
        while not server.should_exit:
            audio.poll_device_changes()
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        server.should_exit = True
        audio.stop()


if __name__ == "__main__":
    main()
