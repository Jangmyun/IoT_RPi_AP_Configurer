"""
wifi_scan.py 실행 테스트
sudo venv/bin/python tests/test_wifi_scan.py
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from wifi_scan import scan_wifi

SIGNAL_BARS = [
    (-50, "████ 매우 강함"),
    (-70, "███  양호"),
    (-80, "██   보통"),
    (-90, "█    약함"),
    (float('-inf'), "     매우 약함"),
]

def signal_bar(dbm: float) -> str:
    for threshold, label in SIGNAL_BARS:
        if dbm >= threshold:
            return label
    return SIGNAL_BARS[-1][1]


def main():
    interface = sys.argv[1] if len(sys.argv) > 1 else "wlan0"
    print(f"\n[*] {interface} 스캔 중... (몇 초 소요)\n")

    try:
        networks = scan_wifi(interface)
    except PermissionError:
        print("[!] root 권한 필요: sudo venv/bin/python tests/test_wifi_scan.py")
        sys.exit(1)

    if not networks:
        print("[!] 스캔 결과 없음")
        return

    print(f"{'#':<4} {'SSID':<32} {'BSSID':<19} {'dBm':>6}  {'신호':16} {'CH':>4}  {'주파수':>8}  {'보안'}")
    print("-" * 100)
    for i, net in enumerate(networks, 1):
        bar = signal_bar(net.signal_dbm)
        print(
            f"{i:<4} {net.ssid:<32} {net.bssid:<19} {net.signal_dbm:>6.1f}  {bar:<16} {net.channel:>4}  {net.frequency:>6}MHz  {net.security}"
        )

    print(f"\n총 {len(networks)}개 AP 발견")


if __name__ == "__main__":
    main()
