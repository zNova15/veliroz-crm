# Veliroz CRM

Panel interno del equipo Veliroz. Vive en **https://crm.veliroz.com** (GH Pages + Cloudflare). Cero costo. Cero build step.

Stack: HTML + CSS + JS vanilla + Supabase (BD/Auth/Storage) + Firebase Auth (identidad).

## Setup una sola vez

### 1. Aplicar migración SQL
Copiá TODO el contenido de [`supabase/migrations/004_crm_staff_roles.sql`](supabase/migrations/004_crm_staff_roles.sql) → SQL Editor de Supabase → RUN.

Verificá en Table Editor: `staff`, `staff_invitaciones`, `configuracion`, `pedido_timeline`, `pedido_evidencias`, `audit`.

### 2. Auth Firebase → Supabase (Custom JWT provider)
Studio → **Auth → Providers → Third-party → Custom JWT**:
- Issuer: `https://securetoken.google.com/veliroz-9f23d`
- JWKS URL: `https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com`
- Audience: `veliroz-9f23d`

Sin este paso, Supabase no reconoce los tokens de Firebase y todos caen a anon.

### 3. Bucket privado `veliroz-evidencias`
Storage → New bucket → nombre `veliroz-evidencias`, **privado**, MIME allowlist `image/*, application/pdf`, max 10 MB.

Policies (SQL Editor):
```sql
create policy "staff_read"        on storage.objects for select using (bucket_id = 'veliroz-evidencias' and public.is_staff_any());
create policy "op_insert"         on storage.objects for insert with check (bucket_id = 'veliroz-evidencias' and public.is_op_up());
create policy "repartidor_insert" on storage.objects for insert with check (bucket_id = 'veliroz-evidencias' and public.is_repartidor());
```

### 4. DNS + GH Pages
GitHub → Settings → Pages: Source `main`, folder `/`, custom domain `crm.veliroz.com`.
Cloudflare DNS: `CNAME crm → <tu-usuario>.github.io`, primero **DNS only** para que GitHub emita SSL. Después: Proxied ON + **Page Rule** `crm.veliroz.com/*` → Cache Level: Bypass (crítico para evitar el max-age=14400 del sitio público).

## Roles

| Rol | Puede |
|---|---|
| creador | TODO. Único (Gabriel). Invita admins. |
| admin | Gestión completa + invita op/repartidor/lector |
| operador | Pedidos, pagos, clientes, catálogo (sin costo) |
| repartidor | Pedidos asignados + marcar entregado con foto |
| lector | Read-only |

## Módulos P1

`/pages/dashboard/` KPIs · `/pages/pedidos/` lista+detalle · `/pages/pagos/` bandeja voucher · `/pages/reparto/` mobile-first entregas · `/pages/clientes/` directorio · `/pages/productos/` catálogo · `/pages/reportes/` ingresos + CSV · `/pages/usuarios/` equipo + invitaciones · `/pages/ajustes/` config KV + perfil.

## Invitar staff nuevo

1. `/pages/usuarios/` → botón Invitar.
2. Email + nombre + rol + teléfono → Generar link.
3. Compartir el link `crm.veliroz.com/?invite=TOKEN` por WhatsApp.
4. Invitado abre el link → login Firebase con ese email → auto-promovido a staff.

## Seguridad

- `anon key` en el bundle (segura por diseño, RLS es la barrera).
- `service_role` **NUNCA** en el frontend (a diferencia del `/admin/` viejo).
- Cada acción sensible pasa por RPC `SECURITY DEFINER` con validación de rol.
- Todas las funciones tienen `search_path` fijo.
- Owner Gabriel es invisible para otros admins futuros (`es_owner=true`).
- Timeline por trigger: cada cambio de estado queda logueado con actor y rol.

## Deploy

```bash
git push origin main
```

GH Pages actualiza en ~30s. Con la Page Rule Cache Bypass, los cambios se ven inmediatamente.
