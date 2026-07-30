-- Bloque diagnóstico 004a_tables_helpers (subset del 004)
create extension if not exists "pgcrypto";
create extension if not exists "citext";

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
    else null::citext
  end;
$$;

-- Helpers de rol: queries directos, sin array polimórfico (evita ERROR 42804).
create or replace function public.is_creador()
returns boolean language sql stable security definer set search_path = public, pg_catalog as $$
  select exists(select 1 from public.staff s where s.email = public.jwt_email() and s.activo = true and s.rol = 'creador');
$$;

create or replace function public.is_admin_up()
returns boolean language sql stable security definer set search_path = public, pg_catalog as $$
  select exists(select 1 from public.staff s where s.email = public.jwt_email() and s.activo = true and s.rol in ('creador','admin'));
$$;

create or replace function public.is_op_up()
returns boolean language sql stable security definer set search_path = public, pg_catalog as $$
  select exists(select 1 from public.staff s where s.email = public.jwt_email() and s.activo = true and s.rol in ('creador','admin','operador'));
$$;

create or replace function public.is_operador()
returns boolean language sql stable security definer set search_path = public, pg_catalog as $$
  select exists(select 1 from public.staff s where s.email = public.jwt_email() and s.activo = true and s.rol = 'operador');
$$;

create or replace function public.is_repartidor()
returns boolean language sql stable security definer set search_path = public, pg_catalog as $$
  select exists(select 1 from public.staff s where s.email = public.jwt_email() and s.activo = true and s.rol = 'repartidor');
$$;

create or replace function public.is_lector()
returns boolean language sql stable security definer set search_path = public, pg_catalog as $$
  select exists(select 1 from public.staff s where s.email = public.jwt_email() and s.activo = true and s.rol = 'lector');
$$;

create or replace function public.is_staff_any()
returns boolean language sql stable security definer set search_path = public, pg_catalog as $$
  select exists(select 1 from public.staff s where s.email = public.jwt_email() and s.activo = true);
$$;

-- Compat: signatura vieja is_staff(text[]) por si algún día alguien la necesita — con literal text[] casteado internamente
create or replace function public.is_staff(roles text[])
returns boolean language sql stable security definer set search_path = public, pg_catalog as $$
  select exists(select 1 from public.staff s where s.email = public.jwt_email() and s.activo = true and s.rol = any(roles));
$$;

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
