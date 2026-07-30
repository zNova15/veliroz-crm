/* Veliroz CRM · Auth
   1) Firebase login (email/pass o Google)
   2) getIdToken → Supabase signInWithIdToken (Custom JWT Provider)
   3) whoami() consulta staff (RPC mi_staff) o cae al fallback anon (RLS bloquea).
   4) Si el email no está en staff activo → logout + mensaje "sin acceso".
   ============================================================
   Nota: la config del Custom JWT provider en Supabase Studio → Auth →
   Third-party → agregar "Firebase" con:
     Issuer: https://securetoken.google.com/veliroz-9f23d
     JWKS URL: https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com
   Sin ese setup, Supabase NO reconoce el token de Firebase.
   ============================================================ */
window.velAuth = (() => {
  'use strict';
  const CFG = window.VELIROZ_CRM;
  let fbApp = null, fbAuth = null;
  let currentUser = null;   // { email, uid, displayName, photoURL }
  let whoami = null;        // { email, nombre, rol, activo, es_owner, foto_url }
  const listeners = [];

  function on(fn) { listeners.push(fn); }
  function emit() { listeners.forEach(fn => { try { fn(whoami); } catch (e) { console.error(e); } }); }
  function getWho() { return whoami; }
  function currentFbUser() { return currentUser; }

  function init() {
    if (fbAuth) return;
    fbApp = firebase.apps.length ? firebase.app() : firebase.initializeApp(CFG.firebase);
    fbAuth = firebase.auth();
    fbAuth.onAuthStateChanged(async user => {
      currentUser = user ? { email: user.email, uid: user.uid, displayName: user.displayName, photoURL: user.photoURL } : null;
      if (!user) { window.sb.setSession(null); whoami = null; emit(); return; }
      try { await afterLogin(user); }
      catch (e) { console.error('[auth]', e); whoami = null; window.sb.setSession(null); emit(); }
    });
  }

  async function afterLogin(user) {
    // 1. Obtener idToken de Firebase y pasarlo a Supabase
    const idToken = await user.getIdToken(true);
    // 2. Intento intercambio con Supabase (signInWithIdToken via REST directo — evita SDK)
    //    Supabase espera un Custom JWT provider configurado.
    const swap = await fetch(`${CFG.supabase.url}/auth/v1/token?grant_type=id_token`, {
      method: 'POST',
      headers: { apikey: CFG.supabase.anonKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ provider: 'firebase', id_token: idToken, access_token: idToken })
    });
    if (swap.ok) {
      const data = await swap.json();
      if (data.access_token) window.sb.setSession(data.access_token);
    } else {
      // Fallback: usar el idToken de Firebase directo si Supabase acepta Custom JWT sin swap
      // (algunas configs devuelven 400 en el swap pero aceptan el JWT en headers si el issuer está whitelisted)
      window.sb.setSession(idToken);
    }

    // 3. whoami() vía RPC mi_staff — devuelve fila si el email está en staff activo
    try {
      whoami = await window.sb.rpc('mi_staff');
    } catch (e) {
      console.warn('[auth] mi_staff falló:', e.message);
      whoami = null;
    }

    // 4. Si no hay staff activo pero hay ?invite=TOKEN, intentar aceptar la invitación
    if (!whoami || !whoami.activo) {
      const inviteToken = new URLSearchParams(location.search).get('invite');
      if (inviteToken) {
        try {
          await window.sb.rpc('aceptar_invitacion', { p_token: inviteToken });
          whoami = await window.sb.rpc('mi_staff');
        } catch (e) { console.warn('[auth] invitación falló:', e.message); }
      }
    }

    // 5. Última chance: si sigue sin staff, logout
    if (!whoami || !whoami.activo) {
      await fbAuth.signOut();
      alert('Tu email no tiene acceso al CRM Veliroz. Pedile a Gabriel que te invite.');
      return;
    }

    // Guardar snapshot ligero en localStorage
    try { localStorage.setItem('vel_crm_whoami', JSON.stringify(whoami)); } catch {}
    emit();
  }

  async function loginEmail(email, pass) { init(); await fbAuth.signInWithEmailAndPassword(email, pass); }
  async function loginGoogle() { init(); const p = new firebase.auth.GoogleAuthProvider(); await fbAuth.signInWithPopup(p); }
  async function logout() { if (!fbAuth) init(); await fbAuth.signOut(); try { localStorage.removeItem('vel_crm_whoami'); } catch {} location.href = '/'; }

  /* Guard para páginas: si el user no tiene rol permitido, redirige.
     Uso: velAuth.guard(['creador','admin','operador']) */
  function guard(rolesPermitidos) {
    on(who => {
      if (!who) { location.href = '/'; return; }
      if (rolesPermitidos && !rolesPermitidos.includes(who.rol)) {
        alert('No tenés permiso para ver esta sección.');
        location.href = '/pages/dashboard/';
      }
    });
    // Restaurar de localStorage mientras Firebase inicia (evita flicker)
    try {
      const cached = JSON.parse(localStorage.getItem('vel_crm_whoami') || 'null');
      if (cached && cached.activo) { whoami = cached; emit(); }
    } catch {}
  }

  init();
  return { init, on, loginEmail, loginGoogle, logout, guard, getWho, currentFbUser };
})();
