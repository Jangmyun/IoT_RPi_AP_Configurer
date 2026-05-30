# IoT_RPi_AP_Configurer

라즈베리파이 AP 모드를 활용한 IoT 기기 Wi-Fi 설정 / 다중 홉 릴레이 구성 도구.

`setup.sh` 한 번으로 RPi를 **AP + (필요 시) STA** 로 구성하여, 최대 3홉짜리 Wi-Fi 릴레이 네트워크를 자동 셋업한다.

```
[Internet] ── eth0/wlan ── (RPi #1, HOP=1) ──Wi-Fi── (RPi #2, HOP=2) ──Wi-Fi── (RPi #3, HOP=3) ── 클라이언트
              192.168.101.1/24                 192.168.102.1/24                  192.168.103.1/24
              SSID: iot2-1                     SSID: iot2-2                      SSID: iot2-3
              CH 1                             CH 6                              CH 11
```

각 홉 RPi는 **자기 AP 서브넷의 게이트웨이**이자, **상위 홉 AP의 STA(.2)** 가 된다.

---

## 사용 방법

각 RPi에서 동일하게 실행하고, 홉 번호만 다르게 입력한다.

```bash
sudo ./setup.sh
```

대화형 프롬프트:

1. **홉 번호** (`1` / `2` / `3`)
   - `1` = 인터넷 게이트웨이, `2` = 중간 릴레이, `3` = 끝단
2. **인터페이스 자동 감지**
   - USB Wi-Fi 동글(`wlx*`)을 찾아 AP 모드 지원 여부 확인
   - 동글이 AP 지원 → AP=동글, STA=`wlan0`
   - 동글이 AP 미지원 → 자동 스왑: AP=`wlan0`, STA=동글
   - 동글 없음 → `ap0` 가상 인터페이스(`wlan0` 공유) 사용 여부 확인
3. **WAN 인터페이스** (HOP=1 한정): `eth0` 또는 STA용 Wi-Fi
4. **채널** (기본값: HOP1=1, HOP2=6, HOP3=11 — 2.4GHz 비중첩)
5. **설정 확인** 후 진행

완료 후 재부팅하면 systemd 유닛이 동일 구성을 자동으로 복원한다.

### 고정 규칙

| 항목 | 값 |
| --- | --- |
| WPA2 PSK (공통) | `00000000` |
| 서브넷 | `192.168.{100+HOP}.0/24` |
| AP IP | `192.168.{100+HOP}.1` |
| 다음 홉 STA IP | `192.168.{100+HOP}.2` (고정) |
| DHCP 범위 | `.10 ~ .100` |
| SSID | `iot2-{HOP}` |
| Country / regdom | `KR` |

---

## 디렉터리 구조

```
.
├── setup.sh              # 오케스트레이션 (모듈 source + 호출 순서만)
└── sh_lib/
    ├── common.sh         # 상수(WPA_PASS, DEFAULT_CHANNEL), log_step, write_state_env
    ├── inputs.sh         # 대화형 입력, 인터페이스 자동 감지, 채널 결정
    ├── ap.sh             # hostapd.conf / dnsmasq.conf / AP 인터페이스 / NAT
    ├── routing.sh        # IP 포워딩, default route, 다운스트림 라우트
    ├── sta.sh            # STA 측 (HOP>1) — dhcpcd 정적 IP, wpa_supplicant, NM 정리
    ├── boot.sh           # /usr/local/bin/rpi-ap-boot.sh 동적 생성
    └── services.sh       # systemd 유닛, 활성화, 최종 상태 출력
```

`setup.sh`는 위 모듈을 `source` 한 뒤 호출 순서만 기술한다 — 실제 로직은 모듈에 있다.

---

## 실행 순서 (setup.sh가 하는 일)

### 1. 입력 수집 단계 (`inputs.sh` + `common.sh`)

| 함수 | 동작 |
| --- | --- |
| `prompt_hop` | HOP 입력 → `SUBNET`, `AP_IP`, `DHCP_START/END`, `SSID` 계산 |
| `detect_interfaces` | `iw dev`로 동글 탐지 → `_phy_supports_ap`로 AP 모드 확인 후 AP/STA 인터페이스 결정 (필요 시 스왑 또는 `ap0` 폴백) |
| `prompt_wan` | HOP=1만: `eth0` 또는 STA Wi-Fi 선택 |
| `compute_next_hop` | HOP<3: `NEXT_HOP_IP = 192.168.{SUBNET}.2` |
| `prompt_channel` | 동글: HOP별 권장 채널(1/6/11) — 오버라이드 허용 / `ap0`: STA가 잡은 채널과 일치해야 함 |
| `confirm_settings` | 요약 출력 후 y/N |
| `write_state_env` | `/etc/rpi-ap/state.env` 작성 (검증 스크립트 참조용) |

### 2. 시스템 적용 단계 (`log_step 1..8`)

| Step | 작업 | 호출 |
| --- | --- | --- |
| 1/8 | dnsmasq / hostapd 중지 | `stop_ap_services` |
| 2/8 | `/etc/hostapd/hostapd.conf` 생성 | `write_hostapd_conf` |
| 3/8 | `/etc/dnsmasq.conf` 생성 | `write_dnsmasq_conf` |
| 4/8 | AP 인터페이스 설정 | `configure_ap_interface` |
| 5/8 | IP 포워딩 활성화 | `enable_ip_forward` |
| 6/8 | 정적 라우팅 (HOP>1 default GW) | `setup_default_route` |
| 7/8 | dnsmasq 시작 + NAT (HOP=1만) | `start_dnsmasq_service` → `setup_nat` |
| 8/8 | 부팅 자동 시작 설정 | (이후 단계로 이어짐) |

`write_hostapd_conf` 는 **거리 우선 모드** 로 작성된다:
- `hw_mode=g` + `channel`, `ieee80211n=1`, HT20 + long GI
- `basic_rates=10 20 55 110` (DSSS 1/2/5.5/11 Mbps) — 비콘/관리 프레임 도달거리 우선
- `rts_threshold=256`, `beacon_int=200`, `dtim_period=2`
- `country_code=KR`, WPA2-PSK / CCMP

`configure_ap_interface` 는:
- NetworkManager가 있으면 `/etc/NetworkManager/conf.d/rpi-ap-unmanaged.conf` 작성해 AP_IF(필요 시 STA_IF도) `unmanaged` 처리
- `wpa_supplicant` 잔여 인스턴스 종료 (hostapd가 nl80211 소켓을 잡기 위함)
- `ap0`: `iw dev wlan0 interface add ap0 type __ap` 후 UP + IP 부여
- 동글/wlan0: IP만 할당하고 DOWN 유지 (hostapd가 UP)

### 3. STA 측 (`sta.sh`) — HOP>1만 실제 적용

전 함수가 `[[ "$HOP" -le 1 ]] && return 0` 가드를 가져 main에서 무조건 호출 가능.

| 함수 | 동작 |
| --- | --- |
| `write_sta_static_ip_dhcpcd` | `/etc/dhcpcd.conf` 에 `# BEGIN/END rpi-ap-sta` 블록으로 STA_IF 정적 IP 등록 |
| `write_sta_wpa_conf` | `wpa_supplicant-{STA_IF}.conf` + 글로벌 `wpa_supplicant.conf` 둘 다 업스트림 SSID 하나만 남도록 덮어쓰기 (`update_config=0`, `priority=10`, `scan_ssid=1`) |
| `cleanup_nm_wifi_profiles` | `nmcli`로 저장된 모든 Wi-Fi 프로필 삭제 (옛 SSID 자동 연결 차단) |
| `disable_conflicting_wpa_services` | 글로벌 `wpa_supplicant.service` 비활성화, AP=wlan0 스왑 시 `wpa_supplicant@wlan0` 도 |
| `restart_sta_wpa` | 잔여 인스턴스 kill 후 `wpa_supplicant@{STA_IF}` 재시작 |
| `assign_sta_ip_immediate` | association 대기 후 STA_IF에 정적 IP + default route 즉시 부여 (dhcpcd 미적용 케이스 대비) |

### 4. 부팅 스크립트 + systemd (`boot.sh`, `services.sh`)

`generate_boot_script` 는 `/usr/local/bin/rpi-ap-boot.sh` 를 동적으로 생성한다:
- `iw reg set KR`, AP_IF 등장 대기(최대 20초)
- NM/wpa_supplicant 점유 해제, down/up 사이클
- HOP>1: STA_IF용 wpa_supplicant 재시작, association 대기, 정적 IP/default route 부여, TX power 2000mBm
- `ap0` 인 경우 가상 인터페이스 재생성
- AP_IF UP + IP + `ip_forward=1`, AP TX power 2000mBm (hostapd 점유 후 적용되도록 5초 지연)
- HOP<3: 다운스트림 라우트 `ip route replace`
- HOP=1: iptables NAT 규칙 재적용

`write_systemd_units` 는 세 유닛을 작성:

| 유닛 | 역할 |
| --- | --- |
| `rpi-ap-setup.service` | `rpi-ap-boot.sh` 실행 (oneshot, `Before=hostapd.service dnsmasq.service rpi-ap-server.service`) |
| `rpi-ap-server.service` | `${PROJECT_DIR}/venv/bin/python -m src.main` (FastAPI 서버, `After=rpi-ap-setup hostapd dnsmasq`) |
| `hostapd.service.d/rpi-ap.conf` | drop-in: `Type=simple` + `ExecStart=/usr/sbin/hostapd /etc/hostapd/hostapd.conf` |

`activate_services` 는 `daemon-reload` → `unmask hostapd` → `enable hostapd dnsmasq rpi-ap-setup rpi-ap-server` → `rfkill unblock wifi` → `hostapd` / `rpi-ap-server` 시작. hostapd 실패 시 `journalctl -u hostapd` 마지막 20줄 출력.

### 5. 다운스트림 라우트 (`add_downstream_routes`)

HOP<3 한정. hostapd가 AP_IF를 UP 시킨 뒤에야 `.2` 게이트웨이가 reachable하므로 `activate_services` 이후 호출. AP_IF가 `state UP` 될 때까지 최대 10초 대기 후 `ip route replace 192.168.{100+i}.0/24 via {NEXT_HOP_IP}` 를 다운스트림 모든 홉에 적용.

### 6. 최종 상태 출력 (`print_final_status`)

`ip addr show {AP_IF}`, `ip route` 요약, `dnsmasq` active 여부, HOP별 E2E 검증 가이드(ping/iperf3) 출력.

---

## 재부팅 후 동작

`rpi-ap-setup.service` → `rpi-ap-boot.sh` 가 인터페이스/라우팅/NAT 를 복원하고, 이후 `hostapd` · `dnsmasq` · `rpi-ap-server` 가 차례로 기동한다. `/etc/rpi-ap/state.env` 가 현재 구성 상태의 단일 소스.

## 요구 사항

- Raspberry Pi OS (Bullseye 이상 권장)
- `hostapd`, `dnsmasq`, `iw`, `iptables`, `wpa_supplicant`, (선택) `nmcli`
- HOP=1은 인터넷 연결(`eth0` 또는 STA용 Wi-Fi)
- `${PROJECT_DIR}/venv` 에 FastAPI 서버 의존성 설치 (`src/main`)
