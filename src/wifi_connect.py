import re
import subprocess
import time

from .models import ConnectResponse

INTERFACE = "wlan0"
HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"


# ── AP 인터페이스 유틸 ──────────────────────────────────────────────────────────

def _get_ap_interface() -> str:
    """hostapd.conf에서 AP 인터페이스 이름 읽기."""
    try:
        with open(HOSTAPD_CONF) as f:
            for line in f:
                if line.startswith("interface="):
                    return line.split("=", 1)[1].strip()
    except FileNotFoundError:
        pass
    return "ap0"


def _get_ap_channel(ap_if: str) -> int | None:
    """iw dev 로 현재 AP 인터페이스 채널 반환."""
    r = subprocess.run(["iw", "dev", ap_if, "info"], capture_output=True, text=True)
    m = re.search(r'channel (\d+)', r.stdout)
    return int(m.group(1)) if m else None


def _get_ap_ip() -> str | None:
    """dnsmasq.conf의 dhcp-option=3 에서 AP IP 읽기."""
    try:
        with open("/etc/dnsmasq.conf") as f:
            for line in f:
                m = re.match(r'dhcp-option=3,(\d+\.\d+\.\d+\.\d+)', line)
                if m:
                    return m.group(1)
    except FileNotFoundError:
        pass
    return None


def _freq_for_channel(ch: int) -> int:
    if ch == 14:
        return 2484
    if 1 <= ch <= 13:
        return 2407 + ch * 5
    return 5000 + ch * 5  # 5GHz


def _update_hostapd_conf_channel(ch: int) -> None:
    subprocess.run(
        ["sudo", "sed", "-i", f"s/^channel=.*/channel={ch}/", HOSTAPD_CONF],
        check=False,
    )


def _restart_ap(ap_if: str, ch: int) -> None:
    """CSA 불가 시 hostapd full restart (~3초 순단). ap0 fallback 전용."""
    subprocess.run(["sudo", "systemctl", "stop", "hostapd"], check=False)
    if ap_if == "ap0":
        # 가상 인터페이스: 삭제 후 재생성
        subprocess.run(["sudo", "iw", "dev", "ap0", "del"], check=False)
        subprocess.run(
            ["sudo", "iw", "dev", "wlan0", "interface", "add", "ap0", "type", "__ap"],
            check=False,
        )
        subprocess.run(["sudo", "ip", "link", "set", "ap0", "up"], check=False)
        ap_ip = _get_ap_ip()
        if ap_ip:
            subprocess.run(
                ["sudo", "ip", "addr", "add", f"{ap_ip}/24", "dev", "ap0"],
                check=False,
            )
    else:
        # 물리 인터페이스(wlx* 등): link up만
        subprocess.run(["sudo", "ip", "link", "set", ap_if, "up"], check=False)

    _update_hostapd_conf_channel(ch)
    subprocess.run(["sudo", "systemctl", "start", "hostapd"], check=False)


def reconfigure_ap_channel(new_channel: int) -> str:
    """
    wlan0이 새 채널로 연결된 후 AP 인터페이스 채널을 동기화.

    반환값:
      "unchanged" : 동기화 불필요 (동글 독립 라디오, 이미 일치, 또는 hostapd 미실행)
      "csa"       : 802.11h CSA 성공 (클라이언트 연결 유지)
      "restarting": full restart 실행 (~3초 순단)
    """
    ap_if = _get_ap_interface()

    # USB 동글(wlx*): 독립 물리 라디오 → wlan0 채널과 무관, 동기화 불필요
    if ap_if.startswith("wlx"):
        return "unchanged"

    # hostapd가 실행 중이 아니면 conf 업데이트만
    r = subprocess.run(["sudo", "systemctl", "is-active", "hostapd"],
                       capture_output=True, text=True)
    if r.stdout.strip() != "active":
        _update_hostapd_conf_channel(new_channel)
        return "unchanged"

    current = _get_ap_channel(ap_if)
    if current == new_channel:
        return "unchanged"

    freq = _freq_for_channel(new_channel)

    # CSA 시도 (5 beacon interval ≈ 500ms 카운트다운)
    r = subprocess.run(
        ["sudo", "hostapd_cli", "-i", ap_if, "chan_switch", "5", str(freq), "ht"],
        capture_output=True, text=True,
    )
    if "OK" in r.stdout:
        _update_hostapd_conf_channel(new_channel)
        return "csa"

    # CSA 미지원 드라이버 → full restart
    _restart_ap(ap_if, new_channel)
    return "restarting"


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

    # wlan0 채널 감지 후 AP 채널 동기화 (단일 라디오 노드에서 채널 불일치 방지)
    r = subprocess.run(["iw", "dev", INTERFACE, "info"], capture_output=True, text=True)
    m = re.search(r'channel (\d+)', r.stdout)
    channel_switch = None
    if m:
        new_ch = int(m.group(1))
        result = reconfigure_ap_channel(new_ch)
        if result != "unchanged":
            channel_switch = result

    return ConnectResponse(
        success=True,
        message=f"'{ssid}' 연결 성공",
        ip_address=ip,
        channel_switch=channel_switch,
    )
