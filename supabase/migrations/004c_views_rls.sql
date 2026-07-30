-- Bloque diagnóstico 004c_views_rls (subset del 004)
create extension if not exists "pgcrypto";
create extension if not exists "citext";

-- VIEWS del Dashboard
-- ============================================================
create or replace view public.v_kpis_hoy with (security_invoker = true) as
select
  count(*)                                              as pedidos_hoy,
  count(*) filter (where estado = 'nuevo')              as pedidos_nuevos,
  count(*) filter (where estado in ('pagado','preparando','en_reparto')) as pedidos_activos,
  count(*) filter (where estado = 'entregado')          as entregados,
  sum(total) filter (where estado <> 'cancelado')       as ingresos_hoy,
  sum(ganancia_bruta) filter (where estado <> 'cancelado' and costo_real is not null) as ganancia_hoy
from public.pedidos
where fecha_pedido >= date_trunc('day', now() at time zone 'America/Lima');

create or replace view public.v_repartos_dia with (security_invoker = true) as
select
  p.id, p.pedido_codigo, p.cliente_nombre, p.cliente_telefono, p.cliente_email,
  p.direccion, p.zona_local, p.total, p.metodo_pago, p.repartidor_email,
  p.estado, p.fecha_entrega_acordada, p.notas_internas,
  p.linea_negocio, p.costo_envio,
  s.nombre as repartidor_nombre
from public.pedidos p
left join public.staff s on s.email = p.repartidor_email
where p.metodo_entrega = 'zona_local'
  and p.estado in ('pagado','preparando','en_reparto')
  and (p.fecha_entrega_acordada is null or p.fecha_entrega_acordada >= date_trunc('day', now() at time zone 'America/Lima'));

-- ============================================================
-- RLS de las tablas del CRM
-- ============================================================
alter table public.staff                enable row level security;
alter table public.staff_invitaciones   enable row level security;
alter table public.configuracion        enable row level security;
alter table public.pedido_timeline      enable row level security;
alter table public.pedido_evidencias    enable row level security;
alter table public.audit                enable row level security;

-- STAFF
drop policy if exists staff_admin_all on public.staff;
create policy staff_admin_all on public.staff for all
  using (public.is_admin_up()) with check (public.is_admin_up());

-- Cualquier staff activo ve su propia fila (whoami/mi_staff())
drop policy if exists staff_self_read on public.staff;
create policy staff_self_read on public.staff for select
  using (email = public.jwt_email());

-- STAFF_INVITACIONES: admin/creador crea y lee. El invitado consulta por token (RPC público)
drop policy if exists staff_inv_admin on public.staff_invitaciones;
create policy staff_inv_admin on public.staff_invitaciones for all
  using (public.is_admin_up()) with check (public.is_admin_up());

-- CONFIGURACION: staff any lee no-sensibles; admin_up lee/edita todo
drop policy if exists cfg_admin_all on public.configuracion;
create policy cfg_admin_all on public.configuracion for all
  using (public.is_admin_up()) with check (public.is_admin_up());

drop policy if exists cfg_staff_read on public.configuracion;
create policy cfg_staff_read on public.configuracion for select
  using (public.is_staff_any() and sensible = false);

-- PEDIDO_TIMELINE: staff (menos repartidor propio no aplica: ya filtra por RLS del pedido). Read admin_up + operador
drop policy if exists ptl_admin_all on public.pedido_timeline;
create policy ptl_admin_all on public.pedido_timeline for select
  using (public.is_op_up());

drop policy if exists ptl_repartidor_read on public.pedido_timeline;
create policy ptl_repartidor_read on public.pedido_timeline for select
  using (exists (select 1 from public.pedidos p where p.id = pedido_timeline.pedido_id
                  and p.repartidor_email = public.jwt_email()));

-- PEDIDO_EVIDENCIAS: mismo que timeline
drop policy if exists pev_op_all on public.pedido_evidencias;
create policy pev_op_all on public.pedido_evidencias for all
  using (public.is_op_up()) with check (public.is_op_up());

drop policy if exists pev_repartidor_ins on public.pedido_evidencias;
create policy pev_repartidor_ins on public.pedido_evidencias for insert
  with check (exists (select 1 from public.pedidos p where p.id = pedido_evidencias.pedido_id
                       and p.repartidor_email = public.jwt_email()));

-- AUDIT: solo admin_up lee
drop policy if exists audit_admin_read on public.audit;
create policy audit_admin_read on public.audit for select using (public.is_admin_up());

-- ============================================================
-- Actualizar RLS de las tablas del negocio (creador/admin/operador/repartidor/lector)
-- ============================================================
-- PEDIDOS
drop policy if exists ped_admin_all      on public.pedidos;
create policy ped_admin_all on public.pedidos for all
  using (public.is_admin_up()) with check (public.is_admin_up());

drop policy if exists ped_operador_all   on public.pedidos;
create policy ped_operador_all on public.pedidos for all
  using (public.is_operador()) with check (public.is_operador());

drop policy if exists ped_repartidor_r   on public.pedidos;
create policy ped_repartidor_r on public.pedidos for select
  using (public.is_repartidor() and repartidor_email = public.jwt_email());

drop policy if exists ped_repartidor_u   on public.pedidos;
create policy ped_repartidor_u on public.pedidos for update
  using  (public.is_repartidor() and repartidor_email = public.jwt_email())
  with check (public.is_repartidor() and repartidor_email = public.jwt_email());

drop policy if exists ped_lector_r       on public.pedidos;
create policy ped_lector_r on public.pedidos for select using (public.is_lector());

-- LINEAS_PEDIDO
drop policy if exists lin_admin_all on public.lineas_pedido;
create policy lin_admin_all on public.lineas_pedido for all
  using (public.is_admin_up()) with check (public.is_admin_up());

drop policy if exists lin_op_all    on public.lineas_pedido;
create policy lin_op_all on public.lineas_pedido for all
  using (public.is_operador()) with check (public.is_operador());

drop policy if exists lin_rep_r     on public.lineas_pedido;
create policy lin_rep_r on public.lineas_pedido for select
  using (exists (select 1 from public.pedidos p where p.id = lineas_pedido.pedido_id
                  and p.repartidor_email = public.jwt_email() and public.is_repartidor()));

drop policy if exists lin_lec_r     on public.lineas_pedido;
create policy lin_lec_r on public.lineas_pedido for select using (public.is_lector());

-- CLIENTES
drop policy if exists cli_admin_all on public.clientes;
create policy cli_admin_all on public.clientes for all
  using (public.is_admin_up()) with check (public.is_admin_up());

drop policy if exists cli_op_read   on public.clientes;
create policy cli_op_read on public.clientes for select using (public.is_operador());

drop policy if exists cli_lec_read  on public.clientes;
create policy cli_lec_read on public.clientes for select using (public.is_lector());

-- CATALOGO: read pública sigue (para el sitio público), edición solo admin_up
drop policy if exists cat_admin_all on public.catalogo;
create policy cat_admin_all on public.catalogo for all
  using (public.is_admin_up()) with check (public.is_admin_up());

-- EVENTOS_CARRITO
drop policy if exists ev_admin_all on public.eventos_carrito;
create policy ev_admin_all on public.eventos_carrito for all
  using (public.is_admin_up()) with check (public.is_admin_up());

drop policy if exists ev_op_read on public.eventos_carrito;
create policy ev_op_read on public.eventos_carrito for select using (public.is_operador());

-- CUPONES
drop policy if exists cupones_admin_all on public.cupones;
create policy cupones_admin_all on public.cupones for all
  using (public.is_admin_up()) with check (public.is_admin_up());
