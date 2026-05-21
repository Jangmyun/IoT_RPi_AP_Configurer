"""
wifi_connect.py 실행 테스트
sudo venv/bin/python tests/test_wifi_connect.py <ssid> <password>

테스트 전 wlan0 상태(연결된 네트워크 목록, IP)를 스냅샷하고,
테스트 완료 후 해당 상태로 복원합니다.
"""
import sys
import os
import subprocess
import re
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src.wifi_connect import connect_to_ap, _wpa_cli, _get_ip_address

INTERFACE = "wlan0"


# ── 상태 스냅샷 / 복원 ────────────────────────────────────────────────────────

def _snapshot_networks() -> list[dict]:
    """테스트 전 wpa_supplicant 네트워크 목록 저장."""
    _, out = _wpa_cli("list_networks")
    networks = []
    for line in out.splitlines()[1:]:  # 첫 줄은 헤더
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        net_id, ssid, bssid, flags = parts[0], parts[1], parts[2], parts[3]
        _, psk_out = _wpa_cli("get_network", net_id, "psk")
        _, key_mgmt = _wpa_cli("get_network", net_id, "key_mgmt")
        networks.append({
            "id": net_id,
            "ssid": ssid,
            "psk": psk_out,
            "key_mgmt": key_mgmt,
            "enabled": "[DISABLED]" not in flags,
            "current": "[CURRENT]" in flags,
        })
    return networks


def _snapshot_ip() -> str | None:
    """테스트 전 wlan0 IP 저장."""
    return _get_ip_address()


def _restore(snapshot: list[dict], original_ip: str | None) -> None:
    """wpa_supplicant 네트워크와 IP를 스냅샷 상태로 복원."""
    print("\n[*] 원래 상태로 복원 중...")

    # 현재 네트워크 전부 제거
    _, current = _wpa_cli("list_networks")
    for line in current.splitlines()[1:]:
        parts = line.split("\t")
        if parts and parts[0].isdigit():
            _wpa_cli("remove_network", parts[0])

    if not snapshot:
        print("    저장된 네트워크 없음 — 네트워크 목록 비운 상태로 복원 완료")
    else:
        current_net = None
        for net in snapshot:
            _, net_id = _wpa_cli("add_network")
            _wpa_cli("set_network", net_id, "ssid", f'"{net["ssid"]}"')
            if net["psk"] not in ("", "FAIL", "\"\""):
                _wpa_cli("set_network", net_id, "psk", net["psk"])
            else:
                _wpa_cli("set_network", net_id, "key_mgmt", "NONE")
            if net["enabled"]:
                _wpa_cli("enable_network", net_id)
            if net["current"]:
                current_net = net_id

        if current_net is not None:
            _wpa_cli("select_network", current_net)
            print(f"    원래 네트워크 재연결 중 (최대 15초)...")
            for _ in range(15):
                time.sleep(1)
                _, status = _wpa_cli("status")
                if "wpa_state=COMPLETED" in status:
                    break

    # IP 복원: dhclient 또는 정적 재설정
    new_ip = _get_ip_address()
    if new_ip != original_ip:
        if original_ip:
            subprocess.run(["dhclient", "-1", INTERFACE], capture_output=True, timeout=15)
            restored_ip = _get_ip_address()
            print(f"    IP 복원: {new_ip} → {restored_ip}")
        else:
            # 원래 IP 없었으면 현재 IP 해제
            subprocess.run(["dhclient", "-r", INTERFACE], capture_output=True, timeout=10)
            print(f"    IP 해제 완료 (원래 IP 없었음)")
    else:
        print(f"    IP 변화 없음: {new_ip}")

    _wpa_cli("save_config")
    print("[*] 복원 완료")


# ── 테스트 ────────────────────────────────────────────────────────────────────

def test_connect(ssid: str, password: str) -> None:
    print(f"\n[*] 테스트 대상: SSID='{ssid}'")

    # 스냅샷
    snapshot = _snapshot_networks()
    original_ip = _snapshot_ip()
    print(f"[*] 스냅샷: 네트워크 {len(snapshot)}개, IP={original_ip}")
    if snapshot:
        for n in snapshot:
            flag = " ← 현재 연결" if n["current"] else ""
            print(f"    - [{n['id']}] {n['ssid']}{flag}")

    result = None
    try:
        print(f"\n[*] connect_to_ap('{ssid}', '****') 호출...")
        result = connect_to_ap(ssid, password)

        print(f"\n{'[OK]' if result.success else '[FAIL]'} {result.message}")
        if result.ip_address:
            print(f"     IP: {result.ip_address}")

        # 결과 검증
        assert isinstance(result.success, bool), "success 필드가 bool이어야 함"
        assert isinstance(result.message, str) and result.message, "message 필드가 비어있음"
        if result.success:
            assert result.ip_address is not None, "성공 시 ip_address가 있어야 함"
            ip_pattern = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
            assert ip_pattern.match(result.ip_address), f"ip_address 형식 오류: {result.ip_address}"
            print("\n[PASS] 모든 검증 통과")
        else:
            print("\n[INFO] 연결 실패 — ConnectResponse 구조는 정상")

    except PermissionError:
        print("[!] root 권한 필요: sudo venv/bin/python tests/test_wifi_connect.py")
        sys.exit(1)
    except AssertionError as e:
        print(f"\n[FAIL] 검증 실패: {e}")
    finally:
        _restore(snapshot, original_ip)


def main():
    if len(sys.argv) < 3:
        print("사용법: sudo venv/bin/python tests/test_wifi_connect.py <ssid> <password>")
        print("        (Open 네트워크는 password에 빈 문자열 '' 전달)")
        sys.exit(1)

    ssid = sys.argv[1]
    password = sys.argv[2]
    test_connect(ssid, password)


if __name__ == "__main__":
    main()
