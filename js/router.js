/* Veliroz CRM · Shell (sidebar + topbar) render y guard por rol
   Cada página HTML llama: shell.render({ active: 'pedidos' })
   La sidebar se filtra por rol vía matriz de permisos.
   =========================================================== */
window.shell = (() => {
  'use strict';

  // Matriz de permisos: { rol: [ items visibles ] }
  const NAV_ITEMS = [
    { key: 'dashboard', label: 'Dashboard',      icon: 'dashboard',     ruta: '/pages/dashboard/',    section: 'Operación',  roles: ['creador','admin','operador','lector'] },
    { key: 'pedidos',   label: 'Pedidos',        icon: 'receipt_long',  ruta: '/pages/pedidos/',      section: 'Operación',  roles: ['creador','admin','operador','lector'] },
    { key: 'pagos',     label: 'Pagos',          icon: 'payments',      ruta: '/pages/pagos/',        section: 'Operación',  roles: ['creador','admin','operador'] },
    { key: 'reparto',   label: 'Entregas',       icon: 'local_shipping',ruta: '/pages/reparto/',      section: 'Operación',  roles: ['creador','admin','operador','repartidor'] },
    { key: 'clientes',  label: 'Clientes',       icon: 'group',         ruta: '/pages/clientes/',     section: 'Datos',      roles: ['creador','admin','operador','lector'] },
    { key: 'productos', label: 'Productos',      icon: 'inventory_2',   ruta: '/pages/productos/',    section: 'Datos',      roles: ['creador','admin','operador','lector'] },
    { key: 'reportes',  label: 'Reportes',       icon: 'monitoring',    ruta: '/pages/reportes/',     section: 'Análisis',   roles: ['creador','admin','lector'] },
    { key: 'usuarios',  label: 'Equipo',         icon: 'admin_panel_settings', ruta: '/pages/usuarios/', section: 'Administración', roles: ['creador','admin'] },
    { key: 'ajustes',   label: 'Configuración',  icon: 'settings',      ruta: '/pages/ajustes/',      section: 'Administración', roles: ['creador','admin'] },
  ];

  function _sidebarHtml(rol, active) {
    const items = NAV_ITEMS.filter(i => i.roles.includes(rol));
    const sections = {};
    items.forEach(i => { (sections[i.section] = sections[i.section] || []).push(i); });
    let html = '<div class="sidebar-header"><img src="/assets/logo-veliroz.png" alt="Veliroz" class="sidebar-logo"/><div class="brand">Veliroz<small>CRM · ' + window.VELIROZ_CRM.version + '</small></div></div>';
    html += '<nav class="sidebar-nav">';
    for (const sec in sections) {
      html += `<div class="nav-section">${window.ui.esc(sec)}</div>`;
      for (const it of sections[sec]) {
        const isActive = it.key === active;
        html += `<a href="${it.ruta}" class="nav-link${isActive?' active':''}">
          <span class="material-symbols-outlined">${it.icon}</span>${window.ui.esc(it.label)}
        </a>`;
      }
    }
    html += '</nav>';
    html += '<div class="sidebar-footer">Veliroz CRM · Interno</div>';
    return html;
  }

  function _bottomNavHtml(rol, active) {
    // Móvil: 4 items principales
    const items = NAV_ITEMS.filter(i => i.roles.includes(rol)).slice(0,4);
    return '<div class="bottom-nav">' + items.map(i => `
      <a href="${i.ruta}" class="${i.key===active?'active':''}">
        <span class="material-symbols-outlined">${i.icon}</span>${window.ui.esc(i.label)}
      </a>`).join('') + '</div>';
  }

  function _topbarHtml(who, title) {
    const nombre = who.nombre || who.email;
    const inits = window.ui.initials(who.nombre, who.email);
    const roleBadge = window.ui.badgeRol(who.rol);
    return `<h1>${window.ui.esc(title || '')}</h1>
      <div class="topbar-right">
        ${roleBadge}
        <div class="avatar" title="${window.ui.esc(nombre)}" id="topAvatar">${who.foto_url ? '<img src="'+window.ui.esc(who.foto_url)+'"/>' : inits}</div>
        <button class="icon-btn" id="topLogout" title="Cerrar sesión">
          <span class="material-symbols-outlined">logout</span>
        </button>
      </div>`;
  }

  async function _fetchModoPrueba() {
    try {
      const rows = await window.sb.get('configuracion?select=valor&clave=eq.modo_prueba&limit=1');
      return rows && rows[0] && rows[0].valor === true;
    } catch { return false; }
  }

  /* Render principal. Args:
       active: key del item activo (para highlight)
       title:  título del topbar
       roles:  opcional, restringe acceso a esta página */
  async function render(args) {
    args = args || {};
    // Esperar a que velAuth resuelva whoami
    const who = await new Promise(resolve => {
      const initial = window.velAuth.getWho();
      if (initial) { resolve(initial); return; }
      const unsub = window.velAuth.on(w => { if (w) resolve(w); });
    });
    if (!who) return;
    if (args.roles && !args.roles.includes(who.rol)) {
      alert('Sin permiso para ver esta sección.');
      location.href = '/pages/dashboard/';
      return;
    }
    // Inyectar shell
    const app = document.querySelector('.app');
    if (!app) return;
    app.innerHTML = `
      <aside class="sidebar">${_sidebarHtml(who.rol, args.active)}</aside>
      <div class="main">
        <div class="topbar">${_topbarHtml(who, args.title)}</div>
        <div id="modeBanner"></div>
        <div id="pageContent"></div>
      </div>
      ${_bottomNavHtml(who.rol, args.active)}
    `;
    // Handlers
    document.getElementById('topLogout').addEventListener('click', () => window.velAuth.logout());
    document.getElementById('topAvatar').addEventListener('click', () => location.href = '/pages/ajustes/?tab=perfil');
    // Modo prueba
    _fetchModoPrueba().then(on => {
      if (on) document.getElementById('modeBanner').innerHTML =
        '<div class="mode-banner">⚠ Modo prueba activo — las escrituras están marcadas para revisión</div>';
    });
    // Mover el contenido pre-render (que estaba en <div id="pageContent"><!-- ...--></div>)
    const tpl = document.getElementById('pageTemplate');
    if (tpl) document.getElementById('pageContent').innerHTML = tpl.innerHTML;
    // Callback opcional (para que la página arme sus data-loaders)
    if (typeof args.onReady === 'function') args.onReady(who);
    return who;
  }

  return { render, NAV_ITEMS };
})();
