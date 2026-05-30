from typing import Optional

from pydantic import BaseModel


class WiFiNetwork(BaseModel):
    ssid: str
    bssid: str
    signal_dbm: float
    channel: int
    frequency: int
    security: str


class ConnectRequest(BaseModel):
    ssid: str
    password: str


class ConnectResponse(BaseModel):
    success: bool
    message: str
    ip_address: Optional[str] = None
    # "csa": seamless channel switch via 802.11h CSA
    # "restarting": full hostapd restart (brief ~3s disconnection)
    # None: channel unchanged or not applicable (dual-radio node)
    channel_switch: Optional[str] = None
