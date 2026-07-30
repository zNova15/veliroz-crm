/* Veliroz CRM · Wrapper fetch Supabase REST/RPC/Storage
   Auth: Firebase idToken → Supabase JWT (setSession lo pushea desde auth.js) */
window.sb = (() => {
  'use strict';
  const CFG = window.VELIROZ_CRM.supabase;
  let sessionJwt = null;
  function setSession(jwt) { sessionJwt = jwt || null; }
  function getSession() { return sessionJwt; }
  function _headers(extra) {
    const bearer = sessionJwt || CFG.anonKey;
    return Object.assign({
      apikey: CFG.anonKey,
      Authorization: 'Bearer ' + bearer,
      'Content-Type': 'application/json',
      Prefer: 'return=representation'
    }, extra || {});
  }
  async function _handle(res) {
    if (!res.ok) {
      const t = await res.text();
      let msg;
      try { const j = JSON.parse(t); msg = j.message || j.hint || j.code || t; } catch { msg = t; }
      const err = new Error((msg || '').substring(0, 220));
      err.status = res.status; throw err;
    }
    const t = await res.text();
    return t ? JSON.parse(t) : null;
  }
  async function get(path)   { return _handle(await fetch(`${CFG.url}/rest/v1/${path}`, { headers: _headers() })); }
  async function post(path, body, extra)  { return _handle(await fetch(`${CFG.url}/rest/v1/${path}`, { method:'POST',  headers:_headers(extra), body: JSON.stringify(body) })); }
  async function patch(path, body, extra) { return _handle(await fetch(`${CFG.url}/rest/v1/${path}`, { method:'PATCH', headers:_headers(extra), body: JSON.stringify(body) })); }
  async function del(path)   { return _handle(await fetch(`${CFG.url}/rest/v1/${path}`, { method:'DELETE', headers:_headers() })); }
  async function rpc(fn, args) {
    return _handle(await fetch(`${CFG.url}/rest/v1/rpc/${fn}`, { method:'POST', headers:_headers(), body: JSON.stringify(args || {}) }));
  }
  async function upload(bucket, path, file, contentType) {
    const bearer = sessionJwt || CFG.anonKey;
    const res = await fetch(`${CFG.url}/storage/v1/object/${bucket}/${encodeURIComponent(path)}`, {
      method:'POST',
      headers: { apikey: CFG.anonKey, Authorization:'Bearer '+bearer, 'Content-Type': contentType || (file.type || 'application/octet-stream'), 'x-upsert':'true' },
      body: file
    });
    return _handle(res);
  }
  async function signedUrl(bucket, path, expiresSec) {
    const bearer = sessionJwt || CFG.anonKey;
    const res = await fetch(`${CFG.url}/storage/v1/object/sign/${bucket}/${encodeURIComponent(path)}`, {
      method:'POST', headers: { apikey: CFG.anonKey, Authorization:'Bearer '+bearer, 'Content-Type':'application/json' },
      body: JSON.stringify({ expiresIn: expiresSec || 86400 })
    });
    const j = await _handle(res);
    return j?.signedURL ? (CFG.url + '/storage/v1' + j.signedURL) : null;
  }
  return { setSession, getSession, get, post, patch, del, rpc, upload, signedUrl };
})();
