/* Veliroz CRM · Helpers UI compartidos (escape, toast, modal, fmt, avatar) */
window.ui = (() => {
  'use strict';

  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => (
      { '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]
    ));
  }

  function toast(msg, kind, ms) {
    let t = document.getElementById('velToast');
    if (!t) {
      t = document.createElement('div');
      t.id = 'velToast';
      t.className = 'toast';
      document.body.appendChild(t);
    }
    t.className = 'toast' + (kind ? (' ' + kind) : '');
    t.textContent = msg;
    setTimeout(() => t.classList.add('show'), 10);
    clearTimeout(t._timer);
    t._timer = setTimeout(() => t.classList.remove('show'), ms || 3000);
  }

  function fmtSoles(n) {
    if (n == null || isNaN(n)) return 'S/. —';
    return 'S/. ' + Number(n).toFixed(2);
  }
  function fmtDate(iso) {
    if (!iso) return '—';
    try {
      return new Date(iso).toLocaleString('es-PE', {
        day:'2-digit', month:'short', hour:'2-digit', minute:'2-digit',
        timeZone:'America/Lima'
      });
    } catch { return '—'; }
  }
  function fmtDay(iso) {
    if (!iso) return '—';
    try {
      return new Date(iso).toLocaleString('es-PE', {
        day:'2-digit', month:'short', year:'numeric',
        timeZone:'America/Lima'
      });
    } catch { return '—'; }
  }

  function initials(nombre, email) {
    const s = (nombre || email || '?').trim();
    if (s.includes(' ')) {
      const p = s.split(/\s+/);
      return (p[0][0] + p[p.length-1][0]).toUpperCase();
    }
    return s.substring(0,2).toUpperCase();
  }

  function whatsappUrl(numero, texto) {
    const clean = String(numero||'').replace(/\D/g,'');
    if (clean.length < 7) return '#';
    // Perú: si empieza con 9 y tiene 9 dígitos, agregar 51
    const full = clean.length === 9 && clean.startsWith('9') ? '51' + clean : clean;
    return `https://wa.me/${full}?text=${encodeURIComponent(texto || '')}`;
  }

  function openModal(id) {
    const m = document.getElementById(id);
    if (m) m.classList.remove('hidden');
  }
  function closeModal(id) {
    const m = document.getElementById(id);
    if (m) m.classList.add('hidden');
  }
  function bindModalClose(id) {
    const back = document.getElementById(id);
    if (!back) return;
    back.addEventListener('click', e => { if (e.target === back) closeModal(id); });
  }

  function badgeRol(rol) {
    const cls = 'badge badge-rol-' + esc(rol);
    return `<span class="${cls}">${esc(rol)}</span>`;
  }
  function badgeEstado(estado) {
    return `<span class="badge badge-${esc(estado)}">${esc(String(estado||'').replace('_',' '))}</span>`;
  }

  function debounce(fn, ms) {
    let t; return function() {
      clearTimeout(t);
      const args = arguments;
      t = setTimeout(() => fn.apply(null, args), ms);
    };
  }

  return { esc, toast, fmtSoles, fmtDate, fmtDay, initials, whatsappUrl, openModal, closeModal, bindModalClose, badgeRol, badgeEstado, debounce };
})();
