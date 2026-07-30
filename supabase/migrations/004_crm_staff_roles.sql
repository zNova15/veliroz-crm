-- ============================================================
-- Veliroz CRM · Migración 004 — Staff, roles jerárquicos, timeline,
-- evidencias, config KV, invitaciones + RPCs sensibles.
-- Aplica sobre 001+002+003 (schema base ya vive). Idempotente.
-- Proyecto Supabase: usfpzlxmmgruydqbymsx
-- ============================================================
-- Jerarquía de roles (Gabriel confirmó):
--   creador  → único (Gabriel), no reemplazable, hace TODO, invita admins
--   admin    → todo excepto tocar creadores; invita ops/repartidores/lectores
--   operador → pedidos, pagos, clientes, catálogo (sin costo). No usuarios.
--   repartidor → SOLO pedidos asignados + marcar entregado con foto
--   lector   → read-only (Claudia como observadora, contador externo)
--
-- Auth: Firebase idToken → Supabase JWT (signInWithIdToken) → RLS lee
--       auth.jwt() ->> 'email' + email_verified. La service_role SALE
--       del bundle del frontend (mata el riesgo del /admin/ actual).
-- ============================================================

-- ============================================================
-- STAFF: whitelist de emails con rol + es_owner (invisibilidad)
-- ============================================================
create table if not exists public.staff (
  email             citext primary key,
  nombre            text,
  rol               text not null default 'lector',
  activo            boolean not null default true,
  es_owner          boolean not null default false,        -- solo Gabriel = true
  firebase_uid      text,
  telefono          text,
  foto_url          text,
  invitado_por      citext,
  invitado_at       timestamptz not null default now(),
  ultimo_ingreso_at timestamptz,
  notas             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint staff_rol_check check (rol in ('creador','admin','operador','repartidor','lector'))
);
create index if not exists staff_rol_idx    on public.staff(rol);
create index if not exists staff_activo_idx on public.staff(activo);

drop trigger if exists trg_staff_updated on public.staff;
create trigger trg_staff_updated before update on public.staff
  for each row execute function public.tg_set_updated_at();

-- Seed: Gabriel = creador + es_owner (único, no borrable)
insert into public.staff (email, nombre, rol, activo, es_owner, notas)
values ('grabieljesusjulcasalazar@gmail.com', 'Gabriel Julca Salazar', 'creador', true, true,
        'Owner fundador · rol creador — invisible para otros admins')
on conflict (email) do update set
  rol = 'creador', activo = true, es_owner = true, updated_at = now();

-- ============================================================
-- STAFF_INVITACIONES: tokens para invitar por WhatsApp
-- ============================================================
create table if not exists public.staff_invitaciones (
  token         text primary key default replace(gen_random_uuid()::text, '-', ''),
  email         citext not null,
  nombre        text,
  rol           text not null check (rol in ('admin','operador','repartidor','lector')),
  telefono      text,
  invitado_por  citext not null,
  invitado_at   timestamptz not null default now(),
  usado_at      timestamptz,
  vence_at      timestamptz not null default (now() + interval '30 days'),
  activo        boolean not null default true
);
create index if not exists staff_inv_email_idx on public.staff_invitaciones(email);

-- ============================================================
-- CONFIGURACION KV — Yape/Plin, umbrales, plantillas WA, modo_prueba
-- ============================================================
create table if not exists public.configuracion (
  clave        text primary key,
  valor        jsonb not null,
  descripcion  text,
  sensible     boolean not null default false,   -- true = solo creador ve el valor
  updated_at   timestamptz not null default now(),
  updated_by   citext
);

insert into public.configuracion (clave, valor, descripcion) values
  ('modo_prueba',         to_jsonb(false),                'Banner amarillo global si true'),
  ('envio_gratis_lima',   to_jsonb(80),                    'Umbral gratis Lima (S/.)'),
  ('envio_gratis_caja',   to_jsonb(40),                    'Umbral gratis Cajamarca (S/.)'),
  ('costo_zonas',         '{"puylucana":0,"banos_inca":3,"cajamarca_ciudad":5}'::jsonb, 'S/. entrega personal'),
  ('yape',                '{"numero":"967456364","nombre":"Gabriel Julca"}'::jsonb, 'Datos Yape'),
  ('plin',                '{"numero":"950211475","nombre":"Gabriel Julca"}'::jsonb, 'Datos Plin'),
  ('banco',               '{"banco":"BCP","titular":"Gabriel Julca","cuenta":"245-00098391-0-10","cci":"002-245-100098391910-99"}'::jsonb, 'Datos banco'),
  ('wa_saludo',           to_jsonb('Hola {nombre}! Te escribo de Veliroz 🌸'),                                'Plantilla WA saludo'),
  ('wa_confirmacion',     to_jsonb('Confirmamos tu pedido {codigo} por S/. {total}. Coordinamos entrega hoy!'), 'Plantilla WA confirmación'),
  ('wa_llegando',         to_jsonb('Hola {nombre}, ya estoy llegando con tu pedido {codigo}!'),               'Plantilla WA repartidor'),
  ('wa_recordatorio_pago',to_jsonb('Recordatorio: falta el voucher de tu pedido {codigo} (S/. {total})'),     'Plantilla WA recordar voucher')
on conflict (clave) do nothing;

-- ============================================================
-- Columnas nuevas en PEDIDOS (asignación repartidor + costo real + origen)
-- ============================================================
alter table public.pedidos
  add column if not exists repartidor_email        citext,
  add column if not exists asignado_at             timestamptz,
  add column if not exists asignado_por            citext,
  add column if not exists fecha_entrega_acordada  timestamptz,
  add column if not exists notas_internas          text,
  add column if not exists origen                  text default 'web';   -- 'web'|'whatsapp'|'telefono'|'presencial'|'import'

create index if not exists pedidos_repartidor_idx on public.pedidos(repartidor_email);
create index if not exists pedidos_entrega_dia_idx on public.pedidos(fecha_entrega_acordada);

-- ============================================================
-- PEDIDO_TIMELINE — auditoría automática por trigger
-- ============================================================
create table if not exists public.pedido_timeline (
  id            bigserial primary key,
  pedido_id     uuid not null references public.pedidos(id) on delete cascade,
  actor_email   citext,
  actor_rol     text,
  evento        text not null,
  desde_estado  text,
  hasta_estado  text,
  data          jsonb,
  created_at    timestamptz not null default now()
);
create index if not exists pedido_timeline_pid_idx on public.pedido_timeline(pedido_id, created_at desc);

-- ============================================================
-- PEDIDO_EVIDENCIAS — vouchers de pago + fotos de entrega
-- ============================================================
create table if not exists public.pedido_evidencias (
  id             uuid primary key default gen_random_uuid(),
  pedido_id      uuid not null references public.pedidos(id) on delete cascade,
  tipo           text not null check (tipo in ('voucher_pago','foto_entrega','otro')),
  storage_path   text not null,                            -- veliroz-evidencias/<pedido>/<uuid>.jpg
  subido_por     citext,
  subido_por_rol text,
  metadata       jsonb,
  created_at     timestamptz not null default now()
);
create index if not exists pedido_evid_pid_idx on public.pedido_evidencias(pedido_id, created_at desc);

-- ============================================================
-- AUDIT LOG global (todo cambio de staff/config/pedidos crítico)
-- ============================================================
create table if not exists public.audit (
  id          bigserial primary key,
  actor_email citext,
  actor_rol   text,
  accion      text not null,
  tabla       text,
  registro_id text,
  antes       jsonb,
  despues     jsonb,
  ip          text,
  user_agent  text,
  created_at  timestamptz not null default now()
);
create index if not exists audit_actor_idx   on public.audit(actor_email);
create index if not exists audit_accion_idx  on public.audit(accion);
create index if not exists audit_tabla_idx   on public.audit(tabla, registro_id);
create index if not exists audit_created_idx on public.audit(created_at desc);

-- ============================================================
-- HELPERS RLS con search_path fijo + email_verified obligatorio
-- ============================================================
create or replace function public.jwt_email()
returns citext language sql stable set search_path = public, pg_catalog as $$
  select case
    when coalesce((auth.jwt() ->> 'email_verified')::boolean, false) = true
      then (auth.jwt() ->> 'email')::citext
    else null
  end;
$$;

create or replace function public.is_staff(roles text[])
returns boolean language sql stable security definer set search_path = public, pg_catalog as $$
  select exists(
    select 1 from public.staff s
    where s.email = public.jwt_email()
      and s.activo = true
      and s.rol = any(roles)
  );
$$;

create or replace function public.is_creador()     returns boolean language sql stable as $$ select public.is_staff(array['creador']) $$;
create or replace function public.is_admin_up()    returns boolean language sql stable as $$ select public.is_staff(array['creador','admin']) $$;
create or replace function public.is_op_up()       returns boolean language sql stable as $$ select public.is_staff(array['creador','admin','operador']) $$;
create or replace function public.is_repartidor()  returns boolean language sql stable as $$ select public.is_staff(array['repartidor']) $$;
create or replace function public.is_staff_any()   returns boolean language sql stable as $$ select public.is_staff(array['creador','admin','operador','repartidor','lector']) $$;

-- Compat: is_admin() ahora = creador OR admin (queda backwards-compatible con el /admin/ actual)
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public, pg_catalog as $$
  select exists(
    select 1 from public.staff s
    where s.email = public.jwt_email() and s.activo = true and s.rol in ('creador','admin')
  ) or exists(
    select 1 from public.admins a where a.email = public.jwt_email() and a.activo = true
  );
$$;

-- mi_staff(): fila del user actual (para whoami del frontend)
create or replace function public.mi_staff()
returns jsonb language sql stable security definer set search_path = public, pg_catalog as $$
  select jsonb_build_object(
    'email', s.email, 'nombre', s.nombre, 'rol', s.rol,
    'activo', s.activo, 'es_owner', s.es_owner, 'foto_url', s.foto_url
  ) from public.staff s where s.email = public.jwt_email();
$$;
grant execute on function public.mi_staff() to authenticated;

-- ============================================================
-- Actualizar log_audit del schema base para incluir actor_rol lookup
-- ============================================================
create or replace function public.log_audit(
  p_accion text, p_tabla text default null, p_registro_id text default null,
  p_antes jsonb default null, p_despues jsonb default null
) returns void language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_email citext; v_rol text;
begin
  v_email := public.jwt_email();
  if v_email is null then return; end if;
  select rol into v_rol from public.staff where email = v_email and activo = true;
  insert into public.audit (actor_email, actor_rol, accion, tabla, registro_id, antes, despues)
  values (v_email, coalesce(v_rol, 'unknown'), p_accion, p_tabla, p_registro_id, p_antes, p_despues);
end $$;
grant execute on function public.log_audit(text, text, text, jsonb, jsonb) to authenticated;

-- ============================================================
-- TRIGGER: al cambiar estado del pedido, escribir en pedido_timeline
-- ============================================================
create or replace function public.tg_pedido_timeline()
returns trigger language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_email citext; v_rol text;
begin
  v_email := public.jwt_email();
  select rol into v_rol from public.staff where email = v_email;
  if old.estado is distinct from new.estado then
    insert into public.pedido_timeline (pedido_id, actor_email, actor_rol, evento, desde_estado, hasta_estado, data)
    values (new.id, v_email, coalesce(v_rol,'trigger'), 'estado_cambiado', old.estado, new.estado,
            jsonb_build_object('total', new.total));
  end if;
  if old.repartidor_email is distinct from new.repartidor_email then
    insert into public.pedido_timeline (pedido_id, actor_email, actor_rol, evento, data)
    values (new.id, v_email, coalesce(v_rol,'trigger'), 'repartidor_asignado',
            jsonb_build_object('desde', old.repartidor_email, 'hasta', new.repartidor_email));
  end if;
  return new;
end $$;

drop trigger if exists trg_pedido_timeline on public.pedidos;
create trigger trg_pedido_timeline after update on public.pedidos
  for each row execute function public.tg_pedido_timeline();

-- Al crear pedido, timeline inicial
create or replace function public.tg_pedido_timeline_ins()
returns trigger language plpgsql security definer set search_path = public, pg_catalog as $$
begin
  insert into public.pedido_timeline (pedido_id, actor_email, actor_rol, evento, hasta_estado, data)
  values (new.id, public.jwt_email(), 'sistema', 'creado', new.estado,
          jsonb_build_object('canal', new.canal, 'origen', coalesce(new.origen,'web'), 'total', new.total));
  return new;
end $$;

drop trigger if exists trg_pedido_timeline_ins on public.pedidos;
create trigger trg_pedido_timeline_ins after insert on public.pedidos
  for each row execute function public.tg_pedido_timeline_ins();

-- ============================================================
-- RPC: invitar_staff — solo creador/admin, con guardrails de jerarquía
-- ============================================================
create or replace function public.invitar_staff(p_email text, p_nombre text, p_rol text, p_telefono text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_actor citext; v_actor_rol text; v_target citext; v_token text;
begin
  v_actor := public.jwt_email();
  if v_actor is null then raise exception 'unauthorized' using errcode='42501'; end if;
  select rol into v_actor_rol from public.staff where email = v_actor and activo = true;
  if v_actor_rol not in ('creador','admin') then raise exception 'rol_insuficiente' using errcode='42501'; end if;

  v_target := lower(trim(p_email))::citext;
  if v_target is null or v_target = '' then raise exception 'email_invalido' using errcode='22023'; end if;
  if p_rol not in ('admin','operador','repartidor','lector') then raise exception 'rol_invalido' using errcode='22023'; end if;

  -- Admin no puede invitar admin. Solo creador invita admin.
  if v_actor_rol = 'admin' and p_rol = 'admin' then raise exception 'admin_no_puede_admin' using errcode='42501'; end if;
  -- Nadie invita a un creador — hay un solo owner.
  if exists (select 1 from public.staff where email = v_target and rol = 'creador') then
    raise exception 'no_se_toca_creador' using errcode='42501';
  end if;

  insert into public.staff_invitaciones (email, nombre, rol, telefono, invitado_por)
  values (v_target, p_nombre, p_rol, p_telefono, v_actor)
  returning token into v_token;

  perform public.log_audit('staff.invitar', 'staff_invitaciones', v_token, null,
                           jsonb_build_object('email', v_target, 'rol', p_rol));

  return jsonb_build_object('ok', true, 'token', v_token,
                            'link', 'https://crm.veliroz.com/?invite=' || v_token);
end $$;
grant execute on function public.invitar_staff(text, text, text, text) to authenticated;

-- ============================================================
-- RPC: aceptar_invitacion — el invitado al primer login lo llama
-- ============================================================
create or replace function public.aceptar_invitacion(p_token text)
returns jsonb language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_inv record; v_email citext;
begin
  v_email := public.jwt_email();
  if v_email is null then raise exception 'unauthorized' using errcode='42501'; end if;
  select * into v_inv from public.staff_invitaciones
    where token = p_token and activo = true and usado_at is null and vence_at > now();
  if not found then raise exception 'invitacion_invalida' using errcode='22023'; end if;
  if v_inv.email <> v_email then raise exception 'email_no_coincide' using errcode='42501'; end if;

  insert into public.staff (email, nombre, rol, activo, invitado_por, invitado_at, telefono)
  values (v_email, v_inv.nombre, v_inv.rol, true, v_inv.invitado_por, v_inv.invitado_at, v_inv.telefono)
  on conflict (email) do update set rol = excluded.rol, activo = true, updated_at = now();

  update public.staff_invitaciones set usado_at = now(), activo = false where token = p_token;
  perform public.log_audit('staff.acepta', 'staff', v_email::text, null, jsonb_build_object('rol', v_inv.rol));
  return jsonb_build_object('ok', true, 'rol', v_inv.rol);
end $$;
grant execute on function public.aceptar_invitacion(text) to authenticated;

-- ============================================================
-- RPC: desactivar_staff
-- ============================================================
create or replace function public.desactivar_staff(p_email text)
returns jsonb language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_actor citext; v_actor_rol text; v_target citext; v_target_rol text; v_target_owner boolean;
begin
  v_actor := public.jwt_email();
  select rol into v_actor_rol from public.staff where email = v_actor and activo = true;
  if v_actor_rol not in ('creador','admin') then raise exception 'rol_insuficiente' using errcode='42501'; end if;

  v_target := lower(trim(p_email))::citext;
  if v_target = v_actor then raise exception 'no_te_puedes_desactivar' using errcode='42501'; end if;
  select rol, es_owner into v_target_rol, v_target_owner from public.staff where email = v_target;
  if not found then raise exception 'no_encontrado' using errcode='22023'; end if;
  if v_target_owner then raise exception 'owner_intocable' using errcode='42501'; end if;
  if v_actor_rol = 'admin' and v_target_rol in ('creador','admin') then raise exception 'admin_no_puede_admin' using errcode='42501'; end if;

  update public.staff set activo = false, updated_at = now() where email = v_target;
  perform public.log_audit('staff.desactivar', 'staff', v_target::text, jsonb_build_object('rol', v_target_rol), null);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.desactivar_staff(text) to authenticated;

-- ============================================================
-- RPC: asignar_repartidor(pedido_id, email)
-- ============================================================
create or replace function public.asignar_repartidor(p_pedido_id uuid, p_email text)
returns jsonb language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_actor citext; v_actor_rol text; v_target citext;
begin
  v_actor := public.jwt_email();
  select rol into v_actor_rol from public.staff where email = v_actor and activo = true;
  if v_actor_rol not in ('creador','admin','operador') then raise exception 'rol_insuficiente' using errcode='42501'; end if;

  v_target := lower(trim(p_email))::citext;
  if not exists (select 1 from public.staff where email = v_target and rol = 'repartidor' and activo = true) then
    raise exception 'repartidor_invalido' using errcode='22023';
  end if;

  update public.pedidos set
    repartidor_email = v_target,
    asignado_at = now(),
    asignado_por = v_actor,
    updated_at = now()
  where id = p_pedido_id;
  if not found then raise exception 'pedido_no_encontrado' using errcode='22023'; end if;

  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.asignar_repartidor(uuid, text) to authenticated;

-- ============================================================
-- RPC: confirmar_pago(pedido_id, metodo, evidencia_path) — con evidencia obligatoria
-- ============================================================
create or replace function public.confirmar_pago(p_pedido_id uuid, p_metodo text default null, p_evidencia_path text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_actor citext; v_rol text; v_pedido record;
begin
  v_actor := public.jwt_email();
  select rol into v_rol from public.staff where email = v_actor and activo = true;
  if v_rol not in ('creador','admin','operador') then raise exception 'rol_insuficiente' using errcode='42501'; end if;

  select * into v_pedido from public.pedidos where id = p_pedido_id;
  if not found then raise exception 'pedido_no_encontrado' using errcode='22023'; end if;
  if v_pedido.estado not in ('nuevo','pagado') then raise exception 'estado_no_confirmable' using errcode='22023'; end if;

  -- Contra-entrega y MercadoPago aprobado NO exigen voucher; Yape/Plin/Banco SÍ
  if coalesce(p_metodo, v_pedido.metodo_pago) in ('yape','plin','banco') and p_evidencia_path is null then
    raise exception 'evidencia_requerida' using errcode='22023';
  end if;

  if p_evidencia_path is not null then
    insert into public.pedido_evidencias (pedido_id, tipo, storage_path, subido_por, subido_por_rol)
    values (p_pedido_id, 'voucher_pago', p_evidencia_path, v_actor, v_rol);
  end if;

  update public.pedidos set
    estado = 'pagado',
    fecha_pago = coalesce(fecha_pago, now()),
    updated_at = now()
  where id = p_pedido_id;

  perform public.log_audit('pago.confirmar', 'pedidos', p_pedido_id::text,
    jsonb_build_object('estado', v_pedido.estado),
    jsonb_build_object('estado', 'pagado', 'evidencia', p_evidencia_path));

  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.confirmar_pago(uuid, text, text) to authenticated;

-- ============================================================
-- RPC: marcar_entregado(pedido_id, foto_path, cobro_efectivo)
--    Repartidor solo si el pedido le está asignado.
--    Creador/admin/operador pueden marcar sin foto (override).
-- ============================================================
create or replace function public.marcar_entregado(p_pedido_id uuid, p_foto_path text default null, p_cobro_efectivo numeric default null)
returns jsonb language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_actor citext; v_rol text; v_pedido record;
begin
  v_actor := public.jwt_email();
  select rol into v_rol from public.staff where email = v_actor and activo = true;
  if v_rol is null then raise exception 'no_staff' using errcode='42501'; end if;

  select * into v_pedido from public.pedidos where id = p_pedido_id;
  if not found then raise exception 'pedido_no_encontrado' using errcode='22023'; end if;

  if v_rol = 'repartidor' then
    if v_pedido.repartidor_email <> v_actor then raise exception 'no_asignado' using errcode='42501'; end if;
    if p_foto_path is null then raise exception 'foto_requerida' using errcode='22023'; end if;
  end if;

  if v_pedido.estado in ('cancelado','entregado') then raise exception 'estado_ya_final' using errcode='22023'; end if;

  if p_foto_path is not null then
    insert into public.pedido_evidencias (pedido_id, tipo, storage_path, subido_por, subido_por_rol,
                                          metadata)
    values (p_pedido_id, 'foto_entrega', p_foto_path, v_actor, v_rol,
            jsonb_build_object('cobro_efectivo', p_cobro_efectivo));
  end if;

  -- Contra-entrega + cobro efectivo → marca pagado también
  if v_pedido.metodo_pago = 'contra_entrega' and p_cobro_efectivo is not null and p_cobro_efectivo > 0 then
    update public.pedidos set fecha_pago = coalesce(fecha_pago, now()) where id = p_pedido_id;
  end if;

  update public.pedidos set
    estado = 'entregado',
    fecha_entrega = coalesce(fecha_entrega, now()),
    updated_at = now()
  where id = p_pedido_id;

  perform public.log_audit('pedido.entregar', 'pedidos', p_pedido_id::text,
    jsonb_build_object('estado', v_pedido.estado),
    jsonb_build_object('estado', 'entregado', 'foto', p_foto_path, 'cobro', p_cobro_efectivo));

  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.marcar_entregado(uuid, text, numeric) to authenticated;

-- ============================================================
-- RPC: cambiar_estado_pedido(pedido_id, nuevo_estado, notas?)
--    Transiciones libres (creador/admin) + reglas por rol
-- ============================================================
create or replace function public.cambiar_estado_pedido(p_pedido_id uuid, p_nuevo_estado text, p_notas text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_actor citext; v_rol text; v_pedido record; v_ok boolean := false;
begin
  v_actor := public.jwt_email();
  select rol into v_rol from public.staff where email = v_actor and activo = true;
  if v_rol is null then raise exception 'no_staff' using errcode='42501'; end if;

  select * into v_pedido from public.pedidos where id = p_pedido_id;
  if not found then raise exception 'pedido_no_encontrado' using errcode='22023'; end if;
  if p_nuevo_estado not in ('nuevo','pagado','preparando','en_reparto','entregado','cancelado') then
    raise exception 'estado_invalido' using errcode='22023';
  end if;

  if v_rol in ('creador','admin') then
    v_ok := true;
  elsif v_rol = 'operador' then
    v_ok := (v_pedido.estado, p_nuevo_estado) in (
      ('nuevo','pagado'), ('pagado','preparando'), ('preparando','en_reparto'),
      ('nuevo','cancelado'), ('pagado','cancelado'), ('preparando','cancelado')
    );
  elsif v_rol = 'repartidor' then
    v_ok := (v_pedido.repartidor_email = v_actor) and
            (v_pedido.estado, p_nuevo_estado) in (('en_reparto','entregado'));
  end if;

  if not v_ok then raise exception 'transicion_no_permitida' using errcode='42501'; end if;

  update public.pedidos set
    estado = p_nuevo_estado,
    notas_internas = case when p_notas is not null then coalesce(notas_internas || E'\n', '') || '[' || v_actor || '] ' || p_notas else notas_internas end,
    fecha_pago    = case when p_nuevo_estado = 'pagado'    and fecha_pago is null    then now() else fecha_pago end,
    fecha_entrega = case when p_nuevo_estado = 'entregado' and fecha_entrega is null then now() else fecha_entrega end,
    updated_at = now()
  where id = p_pedido_id;

  return jsonb_build_object('ok', true, 'estado', p_nuevo_estado);
end $$;
grant execute on function public.cambiar_estado_pedido(uuid, text, text) to authenticated;

-- ============================================================
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
  using (public.is_staff(array['operador'])) with check (public.is_staff(array['operador']));

drop policy if exists ped_repartidor_r   on public.pedidos;
create policy ped_repartidor_r on public.pedidos for select
  using (public.is_repartidor() and repartidor_email = public.jwt_email());

drop policy if exists ped_repartidor_u   on public.pedidos;
create policy ped_repartidor_u on public.pedidos for update
  using  (public.is_repartidor() and repartidor_email = public.jwt_email())
  with check (public.is_repartidor() and repartidor_email = public.jwt_email());

drop policy if exists ped_lector_r       on public.pedidos;
create policy ped_lector_r on public.pedidos for select using (public.is_staff(array['lector']));

-- LINEAS_PEDIDO
drop policy if exists lin_admin_all on public.lineas_pedido;
create policy lin_admin_all on public.lineas_pedido for all
  using (public.is_admin_up()) with check (public.is_admin_up());

drop policy if exists lin_op_all    on public.lineas_pedido;
create policy lin_op_all on public.lineas_pedido for all
  using (public.is_staff(array['operador'])) with check (public.is_staff(array['operador']));

drop policy if exists lin_rep_r     on public.lineas_pedido;
create policy lin_rep_r on public.lineas_pedido for select
  using (exists (select 1 from public.pedidos p where p.id = lineas_pedido.pedido_id
                  and p.repartidor_email = public.jwt_email() and public.is_repartidor()));

drop policy if exists lin_lec_r     on public.lineas_pedido;
create policy lin_lec_r on public.lineas_pedido for select using (public.is_staff(array['lector']));

-- CLIENTES
drop policy if exists cli_admin_all on public.clientes;
create policy cli_admin_all on public.clientes for all
  using (public.is_admin_up()) with check (public.is_admin_up());

drop policy if exists cli_op_read   on public.clientes;
create policy cli_op_read on public.clientes for select using (public.is_staff(array['operador']));

drop policy if exists cli_lec_read  on public.clientes;
create policy cli_lec_read on public.clientes for select using (public.is_staff(array['lector']));

-- CATALOGO: read pública sigue (para el sitio público), edición solo admin_up
drop policy if exists cat_admin_all on public.catalogo;
create policy cat_admin_all on public.catalogo for all
  using (public.is_admin_up()) with check (public.is_admin_up());

-- EVENTOS_CARRITO
drop policy if exists ev_admin_all on public.eventos_carrito;
create policy ev_admin_all on public.eventos_carrito for all
  using (public.is_admin_up()) with check (public.is_admin_up());

drop policy if exists ev_op_read on public.eventos_carrito;
create policy ev_op_read on public.eventos_carrito for select using (public.is_staff(array['operador']));

-- CUPONES
drop policy if exists cupones_admin_all on public.cupones;
create policy cupones_admin_all on public.cupones for all
  using (public.is_admin_up()) with check (public.is_admin_up());
