# VidaActiva

Tienda estática publicada en GitHub Pages, con catálogo e inventario administrados desde Supabase.

## Arquitectura

- Frontend: HTML/CSS/JavaScript existente en GitHub Pages. Se conserva el diseño y el flujo visual de la tienda.
- Backend: Supabase Postgres + Auth + funciones RPC.
- Proyecto Supabase: `kyuexpenylndneekcsaj` (región `eu-west-1`).
- Dominio: `https://vidaactiva.click`.
- SDK del navegador: `@supabase/supabase-js@2.119.2` (versión fijada).
- El navegador usa únicamente la publishable key. Nunca colocar la secret/service_role key en archivos públicos.

## Inventario y pedidos

- Los productos permanecen visibles aunque su stock sea cero.
- Stock cero: se muestra **Agotado** y se bloquean las acciones de compra.
- La creación de un pedido valida cantidades, estado del producto, precio y stock desde PostgreSQL.
- La creación del pedido no reserva ni descuenta existencias.
- El inventario se descuenta exclusivamente en `confirm_store_order_payment`, después de que un administrador verifique el pago.
- La confirmación bloquea las filas de inventario y valida todos los productos antes de descontar cualquiera; si falta stock, la transacción falla sin descuentos parciales.
- Los ajustes manuales de inventario usan `admin_adjust_product_stock` y generan movimientos auditables.
- El cálculo del precio de venta conserva el multiplicador actual de la tienda: `base_price × 2`.

## Panel de administración

Ruta: `https://vidaactiva.click/admin.html`

### Alta inicial del administrador

Por seguridad no hay registro público. En el dashboard de Supabase:

1. Abre **Authentication → Users → Add user** e invita o crea el usuario administrativo.
2. Confirma/verifica el usuario desde Supabase.
3. En **SQL Editor**, ejecuta el siguiente comando sustituyendo el correo por el que registraste:

```sql
insert into public.admin_users (user_id, role)
select id, 'admin'
from auth.users
where lower(email) = lower('TU_CORREO_ADMIN')
on conflict (user_id) do update set role = 'admin';
```

4. Accede a `/admin.html` con ese correo y contraseña.

El panel permite consultar pedidos, marcar pagos en revisión, confirmar o rechazar pagos y actualizar existencias. La confirmación del pago es la única acción que descuenta stock.

## SEO por producto

- El script `scripts/generate-product-pages.mjs` crea una página estática por producto bajo `/producto/<slug>/`.
- Cada página genera canonical, meta description, Open Graph, Twitter Cards y JSON-LD Product.
- Las páginas incluyen enlaces para compartir y volver al detalle de la tienda.
- El workflow `.github/workflows/generate-product-seo.yml` ejecuta el generador al actualizar el catálogo en `main` y actualiza `sitemap.xml`.
- Para probar manualmente: `node scripts/generate-product-pages.mjs`.

## Monitor externo

El workflow `.github/workflows/supabase-keepalive.yml` consulta el endpoint público del catálogo tres veces al día y permite detectar indisponibilidad. **No garantiza impedir la pausa automática de proyectos Supabase Free**; es un monitor externo, no un sustituto de un plan de producción sin pausa.

## Estado inicial del catálogo

- 122 productos importados.
- Todos empiezan con stock 0 hasta que se carguen existencias reales.
- 15 productos no tienen imagen asignada en el catálogo original; se muestra la imagen de respaldo de la tienda.
- El producto ID 47 tiene el precio de origen malformado (`20..`). Se conserva con precio 0 y el checkout lo bloquea hasta que se corrija el dato.
- El inventario debe cargarse desde el panel antes de habilitar ventas.

## Migraciones

Las migraciones de `supabase/migrations/` documentan el esquema base, las políticas RLS y las funciones de inventario/pago. La base del proyecto conectado ya recibió estas migraciones.
