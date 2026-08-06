-- ============================================================
-- Fix: agregar fecha_pedido y datos de comprobante a v_repartos_dia
-- + agregar campos de comprobante a v_repartos_dia para mostrar boleta/factura
-- ============================================================
create or replace view public.v_repartos_dia with (security_invoker = true) as
select
  p.id, p.pedido_codigo, p.cliente_nombre, p.cliente_telefono, p.cliente_email,
  p.direccion, p.zona_local, p.total, p.subtotal, p.costo_envio, p.descuento,
  p.metodo_pago, p.repartidor_email,
  p.estado, p.fecha_pedido, p.fecha_pago, p.fecha_entrega, p.fecha_entrega_acordada,
  p.notas_internas, p.linea_negocio,
  p.tipo_comprobante, p.documento, p.razon_social, p.direccion_fiscal,
  s.nombre as repartidor_nombre
from public.pedidos p
left join public.staff s on s.email = p.repartidor_email
where p.metodo_entrega = 'zona_local'
  and p.estado in ('pagado','preparando','en_reparto')
  and (p.fecha_entrega_acordada is null or p.fecha_entrega_acordada >= date_trunc('day', now() at time zone 'America/Lima'));
