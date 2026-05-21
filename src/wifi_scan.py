import asyncio
import logging
import socket
from typing import List

from pyroute2.iwutil import AsyncIW
from pyroute2.netlink.nl80211 import AsyncNL80211, NL80211_NAMES, nl80211cmd

from .models import WiFiNetwork

log = logging.getLogger(__name__)

_WPA_IE_PREFIX = b'\x00\x50\xf2\x01'
_SCAN_TIMEOUT = 30  # seconds


def _freq_to_channel(freq: int) -> int:
    if freq == 2484:
        return 14
    if 2412 <= freq <= 2472:
        return (freq - 2407) // 5
    if 5180 <= freq <= 5885:
        return (freq - 5000) // 5
    return 0


def _format_bssid(raw) -> str:
    if isinstance(raw, bytes):
        return ':'.join(f'{b:02x}' for b in raw)
    return str(raw)


def _detect_security(ies: dict) -> str:
    if not ies:
        return "Open"
    if "RSN" in ies:
        return "WPA2"
    for vendor_ie in ies.get("VENDOR", []):
        if isinstance(vendor_ie, bytes) and vendor_ie[:4] == _WPA_IE_PREFIX:
            return "WPA"
    return "Open"


def _decode_ssid(raw: bytes) -> str:
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1", errors="replace")


async def _wait_scan_done(nsock: AsyncNL80211) -> None:
    # get(msg_seq=0) yields exactly one multicast msg then stops,
    # so we loop until we see NL80211_CMD_NEW_SCAN_RESULTS.
    while True:
        async for msg in nsock.get():
            if msg.get('event') == 'NL80211_CMD_NEW_SCAN_RESULTS':
                return


async def _scan_async(ifindex: int) -> list:
    iw = AsyncIW()
    await iw.setup_endpoint()

    # Secondary socket for scan-complete events.
    # Must be created BEFORE triggering the scan to avoid race condition.
    # Using AsyncNL80211 (not NL80211) to stay in async context.
    nsock = AsyncNL80211()
    await nsock.bind()
    nsock.add_membership('scan')

    try:
        msg = nl80211cmd()
        msg['cmd'] = NL80211_NAMES['NL80211_CMD_TRIGGER_SCAN']
        msg['attrs'] = [['NL80211_ATTR_IFINDEX', ifindex]]
        await iw._do_request(msg)

        try:
            await asyncio.wait_for(_wait_scan_done(nsock), timeout=_SCAN_TIMEOUT)
        except asyncio.TimeoutError:
            log.warning("scan event timeout after %ds, getting results anyway", _SCAN_TIMEOUT)

        msg2 = nl80211cmd()
        msg2['cmd'] = NL80211_NAMES['NL80211_CMD_GET_SCAN']
        msg2['attrs'] = [['NL80211_ATTR_IFINDEX', ifindex]]
        results = []
        async for result in await iw._do_dump(msg2):
            results.append(result)
        return results
    finally:
        try:
            iw.close()
        except Exception:
            pass
        try:
            nsock.close()
        except Exception:
            pass


def _build_networks(raw: list) -> List[WiFiNetwork]:
    results: List[WiFiNetwork] = []
    seen: set = set()

    for msg in raw:
        bss = msg.get_attr("NL80211_ATTR_BSS")
        if bss is None:
            continue

        bssid_raw = bss.get_attr("NL80211_BSS_BSSID")
        if bssid_raw is None:
            continue
        bssid = _format_bssid(bssid_raw)
        if bssid in seen:
            continue
        seen.add(bssid)

        freq: int = bss.get_attr("NL80211_BSS_FREQUENCY") or 0

        signal_attr = bss.get_attr("NL80211_BSS_SIGNAL_MBM")
        signal_dbm: float = signal_attr["SIGNAL_STRENGTH"]["VALUE"] if signal_attr else -100.0

        ies: dict = (
            bss.get_attr("NL80211_BSS_INFORMATION_ELEMENTS")
            or bss.get_attr("NL80211_BSS_BEACON_IES")
            or {}
        )

        ssid_raw: bytes = ies.get("SSID", b"")
        if not ssid_raw:
            continue
        ssid = _decode_ssid(ssid_raw)
        if not ssid.strip():
            continue

        channel: int = ies.get("CHANNEL") or _freq_to_channel(freq)
        security: str = _detect_security(ies)

        results.append(WiFiNetwork(
            ssid=ssid,
            bssid=bssid,
            signal_dbm=signal_dbm,
            channel=channel,
            frequency=freq,
            security=security,
        ))

    results.sort(key=lambda n: n.signal_dbm, reverse=True)
    return results


async def scan_wifi_async(interface: str = "wlan0") -> List[WiFiNetwork]:
    """Async API — use this from FastAPI endpoints."""
    ifindex = socket.if_nametoindex(interface)
    raw = await _scan_async(ifindex)
    return _build_networks(raw)


def scan_wifi(interface: str = "wlan0") -> List[WiFiNetwork]:
    """Sync API — use this from plain scripts."""
    return asyncio.run(scan_wifi_async(interface))
