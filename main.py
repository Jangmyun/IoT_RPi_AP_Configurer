import asyncio
import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import List

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.requests import Request

from models import ConnectRequest, ConnectResponse, WiFiNetwork
from wifi_connect import connect_to_ap
from wifi_scan import scan_wifi_async

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

BASE_DIR = Path(__file__).parent
templates = Jinja2Templates(directory=BASE_DIR / "templates")


def _signal_level(dbm: float) -> int:
    if dbm >= -50: return 4
    if dbm >= -65: return 3
    if dbm >= -75: return 2
    return 1

templates.env.globals["signal_level"] = _signal_level

app = FastAPI(title="RPi WiFi Configurer")
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")

_scan_cache: List[WiFiNetwork] = []
_scan_lock = asyncio.Lock()


async def _refresh_scan() -> List[WiFiNetwork]:
    global _scan_cache
    async with _scan_lock:
        try:
            _scan_cache = await scan_wifi_async("wlan0")
        except Exception as exc:
            log.warning("scan failed: %s", exc)
    return _scan_cache


@asynccontextmanager
async def lifespan(app: FastAPI):
    asyncio.create_task(_refresh_scan())
    yield

app.router.lifespan_context = lifespan


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    networks = _scan_cache or await _refresh_scan()
    return templates.TemplateResponse(
        request,
        "index.html",
        {"networks": networks},
    )


@app.get("/api/scan", response_model=List[WiFiNetwork])
async def api_scan():
    return await _refresh_scan()


@app.post("/api/connect", response_model=ConnectResponse)
async def api_connect(body: ConnectRequest):
    try:
        result = await asyncio.to_thread(connect_to_ap, body.ssid, body.password)
    except Exception as exc:
        log.exception("connect_to_ap raised unexpectedly")
        raise HTTPException(status_code=500, detail=str(exc))
    return result


@app.get("/api/status")
async def api_status():
    from wifi_connect import _wpa_cli, _get_ip_address
    _, status = _wpa_cli("status")
    connected = "wpa_state=COMPLETED" in status
    ssid = None
    for line in status.splitlines():
        if line.startswith("ssid="):
            ssid = line[5:]
            break
    return {
        "connected": connected,
        "ssid": ssid,
        "ip_address": _get_ip_address() if connected else None,
    }


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=80)
