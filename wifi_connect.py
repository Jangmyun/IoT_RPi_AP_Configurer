import re
import subprocess
import time

from models import ConnectResponse

INTERFACE = "wlan0"


def _wpa_cli(*args: str) -> tuple[int, str]:
    result = subprocess.run(
        ["wpa_cli", "-i", INTERFACE, *args],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout.strip()


def _get_ip_address() -> str | None:
    result = subprocess.run(
        ["ip", "addr", "show", INTERFACE],
        capture_output=True,
        text=True,
    )
    match = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/", result.stdout)
    return match.group(1) if match else None


def connect_to_ap(ssid: str, password: str) -> ConnectResponse:
    # Remove existing networks to avoid stale configs
    _, networks = _wpa_cli("list_networks")
    for line in networks.splitlines()[1:]:
        parts = line.split("\t")
        if parts:
            _wpa_cli("remove_network", parts[0])

    # Add and configure new network
    rc, net_id = _wpa_cli("add_network")
    if rc != 0 or not net_id.isdigit():
        return ConnectResponse(success=False, message="wpa_cli add_network 실패")

    configs = [
        ("ssid", f'"{ssid}"'),
        ("psk", f'"{password}"') if password else ("key_mgmt", "NONE"),
    ]
    for key, value in configs:
        rc, out = _wpa_cli("set_network", net_id, key, value)
        if rc != 0 or out != "OK":
            return ConnectResponse(success=False, message=f"wpa_cli set_network {key} 실패")

    rc, out = _wpa_cli("enable_network", net_id)
    if rc != 0 or out != "OK":
        return ConnectResponse(success=False, message="wpa_cli enable_network 실패")

    rc, out = _wpa_cli("select_network", net_id)
    if rc != 0 or out != "OK":
        return ConnectResponse(success=False, message="wpa_cli select_network 실패")

    # Wait for association (up to 15 seconds)
    for _ in range(15):
        time.sleep(1)
        _, status = _wpa_cli("status")
        if "wpa_state=COMPLETED" in status:
            break
    else:
        return ConnectResponse(success=False, message=f"'{ssid}' 연결 시간 초과 (인증 실패 또는 신호 불량)")

    # Request IP via DHCP
    subprocess.run(
        ["dhclient", "-1", INTERFACE],
        capture_output=True,
        timeout=15,
    )

    ip = _get_ip_address()
    if ip is None:
        return ConnectResponse(success=False, message="연결됐지만 IP 할당 실패")

    _wpa_cli("save_config")
    return ConnectResponse(success=True, message=f"'{ssid}' 연결 성공", ip_address=ip)
