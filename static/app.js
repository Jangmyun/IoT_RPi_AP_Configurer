'use strict';

const backdrop = document.getElementById('modal-backdrop');
const modalTitle = document.getElementById('modal-title');
const modalPw = document.getElementById('modal-pw');
const modalFeedback = document.getElementById('modal-feedback');
const btnConnect = document.getElementById('btn-connect');
const btnCancel = document.getElementById('btn-cancel');
const btnScan = document.getElementById('btn-scan');
const statusBar = document.getElementById('status-bar');
const statusText = document.getElementById('status-text');
const networkList = document.getElementById('network-list');

let selectedSsid = '';

// ── Status bar ────────────────────────────────────────────────────────────────

async function refreshStatus() {
  try {
    const res = await fetch('/api/status');
    if (!res.ok) return;
    const data = await res.json();
    if (data.connected && data.ssid) {
      statusBar.className = 'connected';
      statusText.textContent = `연결됨: ${data.ssid}  (${data.ip_address ?? '–'})`;
    } else {
      statusBar.className = '';
      statusText.textContent = '인터넷 연결 없음';
    }
  } catch {
    statusText.textContent = '상태 확인 실패';
  }
}

refreshStatus();

// ── Scan ──────────────────────────────────────────────────────────────────────

function escHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function signalBarsHtml(dbm) {
  let level;
  if (dbm >= -50) level = 4;
  else if (dbm >= -65) level = 3;
  else if (dbm >= -75) level = 2;
  else level = 1;
  return Array.from({length: 4}, (_, i) =>
    `<div class="bar${i < level ? ' active' : ''}"></div>`
  ).join('');
}

function buildCard(net) {
  const card = document.createElement('div');
  card.className = 'net-card';
  card.dataset.ssid = net.ssid;
  card.dataset.security = net.security;
  const secClass = net.security.toLowerCase().replace(/\s+/g, '');
  card.innerHTML = `
    <div class="signal-bars">${signalBarsHtml(net.signal_dbm)}</div>
    <div class="net-info">
      <div class="net-ssid">${escHtml(net.ssid)}</div>
      <div class="net-meta">${net.signal_dbm.toFixed(1)} dBm &nbsp;·&nbsp; CH ${net.channel} &nbsp;·&nbsp; ${net.frequency} MHz</div>
    </div>
    <div class="net-badge ${secClass}">${escHtml(net.security)}</div>
  `;
  card.addEventListener('click', () => openModal(net.ssid));
  return card;
}

btnScan.addEventListener('click', async () => {
  btnScan.disabled = true;
  btnScan.textContent = '스캔 중…';
  try {
    const res = await fetch('/api/scan');
    const nets = await res.json();
    networkList.innerHTML = '';
    if (nets.length === 0) {
      networkList.innerHTML = '<div class="empty">주변 WiFi가 없습니다.</div>';
    } else {
      nets.forEach(n => networkList.appendChild(buildCard(n)));
    }
  } catch {
    networkList.innerHTML = '<div class="empty">스캔 실패. 다시 시도하세요.</div>';
  } finally {
    btnScan.disabled = false;
    btnScan.innerHTML = '&#x21BB; 스캔';
  }
});

// ── Card click → delegate from server-rendered cards ─────────────────────────

networkList.addEventListener('click', e => {
  const card = e.target.closest('.net-card');
  if (card) openModal(card.dataset.ssid);
});

// ── Connect ───────────────────────────────────────────────────────────────────

btnConnect.addEventListener('click', async () => {
  const password = modalPw.value;
  btnConnect.disabled = true;
  btnConnect.innerHTML = '<span class="spinner"></span>연결 중…';
  setFeedback('연결 시도 중...', '');

  try {
    await fetch('/api/connect', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ssid: selectedSsid, password }),
    });

    // 결과 폴링 (최대 40초, 네트워크 끊김 재시도 포함)
    let networkErrors = 0;
    for (let i = 0; i < 40; i++) {
      await new Promise(r => setTimeout(r, 1000));
      try {
        const res = await fetch('/api/connect_result');
        if (!res.ok) continue;
        const data = await res.json();
        networkErrors = 0;

        if (data.pending) {
          // AP 재시작 중이면 연결이 잠시 끊길 수 있음을 안내
          if (i > 18) setFeedback('AP 채널 조정 중, 잠시 후 자동 재접속됩니다…', '');
          continue;
        }

        if (data.success) {
          const channelMsg = _channelSwitchMsg(data.channel_switch);
          setFeedback(`✓ ${data.message}  IP: ${data.ip_address}${channelMsg}`, 'success');
          btnConnect.textContent = '완료';
          refreshStatus();
          setTimeout(closeModal, data.channel_switch === 'restarting' ? 4000 : 2000);
        } else {
          setFeedback(`✗ ${data.message}`, 'error');
          btnConnect.disabled = false;
          btnConnect.textContent = '다시 시도';
        }
        return;
      } catch {
        // AP 재시작으로 인한 일시적 연결 끊김 → 재시도
        networkErrors++;
        if (networkErrors >= 2) {
          setFeedback('AP 재시작 중, 재접속 대기 중…', '');
        }
      }
    }
    setFeedback('연결 결과 확인 시간 초과', 'error');
    btnConnect.disabled = false;
    btnConnect.textContent = '다시 시도';
  } catch (e) {
    setFeedback(`네트워크 오류: ${e.message}`, 'error');
    btnConnect.disabled = false;
    btnConnect.textContent = '다시 시도';
  }
});

function _channelSwitchMsg(channelSwitch) {
  if (channelSwitch === 'csa') return '\nAP 채널 전환 완료 (CSA)';
  if (channelSwitch === 'restarting') return '\nAP 채널 변경으로 재시작됨 — 자동 재접속됩니다';
  return '';
}

// ── Modal ─────────────────────────────────────────────────────────────────────

function openModal(ssid) {
  selectedSsid = ssid;
  modalTitle.textContent = `"${ssid}" 연결`;
  modalPw.value = '';
  setFeedback('', '');
  btnConnect.disabled = false;
  btnConnect.textContent = '연결';
  backdrop.classList.add('open');
  setTimeout(() => modalPw.focus(), 50);
}

function closeModal() {
  backdrop.classList.remove('open');
  selectedSsid = '';
}

function setFeedback(msg, type) {
  modalFeedback.textContent = msg;
  modalFeedback.className = type;
}

btnCancel.addEventListener('click', closeModal);
backdrop.addEventListener('click', e => { if (e.target === backdrop) closeModal(); });
modalPw.addEventListener('keydown', e => { if (e.key === 'Enter') btnConnect.click(); });
