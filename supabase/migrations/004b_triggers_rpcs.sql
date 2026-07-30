-- Bloque diagnóstico 004b_triggers_rpcs (subset del 004)
create extension if not exists "pgcrypto";
create extension if not exists "citext";

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

  perform public.log_audit('staff.invitar', 'staff_invitaciones', v_token, null::jsonb,
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
  perform public.log_audit('staff.acepta', 'staff', v_email::text, null::jsonb, jsonb_build_object('rol', v_inv.rol));
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
  perform public.log_audit('staff.desactivar', 'staff', v_target::text, jsonb_build_object('rol', v_target_rol), null::jsonb);
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
