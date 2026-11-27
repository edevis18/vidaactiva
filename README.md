# VidaActiva — tienda con Supabase

La tienda conserva su interfaz estática en GitHub Pages y usa Supabase como fuente de productos, existencias, pedidos y comprobantes.

## Infraestructura
- Sitio: https://vidaactiva.click
- Supabase project ref: `kyuexpenylndneekcsaj` (región `eu-west-1`)
- Catálogo importado: 122 productos.
- Frontend: solo clave publishable; nunca guardar claves secret/service_role en el repositorio.
- Edge Functions: `create-order` y `submit-payment-proof`.
- Storage privado: `payment-proofs` (JPG, PNG, WEBP o PDF; 8 MB máximo).

## Flujo de pedidos e inventario
1. El cliente agrega productos con stock disponible.
2. La función `create-order` valida el pedido y registra una orden `pending_payment`; no descuenta ni reserva inventario.
3. El cliente continúa por WhatsApp y usa el enlace `pago.html?pedido=<UUID>` para adjuntar el comprobante y referencia.
4. El pedido pasa a `payment_under_review`.
5. Un administrador verifica el comprobante en `/admin/`.
6. Solo al confirmar el pago se ejecuta `confirm_store_payment`, que vuelve a validar el stock, descuenta todas las líneas en una transacción y registra los movimientos. Si falta stock, el pedido queda `stock_issue` y no se descuenta ninguna unidad.

## Activación del primer administrador
1. Abre `https://vidaactiva.click/admin/` y crea una cuenta con tu correo.
2. Confirma el correo si Supabase Auth lo solicita.
3. Inicia sesión. El panel mostrará el UUID de usuario y el SQL de activación.
4. En Supabase → SQL Editor ejecuta (reemplazando el UUID):
   ```sql
   insert into public.admin_users(user_id,role)
   values ('UUID-DE-TU-USUARIO','admin')
   on conflict (user_id) do nothing;
   ```
5. Cierra sesión y vuelve a entrar. No hay un administrador preasignado y el registro público no concede permisos automáticamente.

## Existencias iniciales
El archivo de catálogo no contiene cantidades verificables. Por seguridad, los 122 productos comienzan con stock `0`. Carga las cantidades reales desde `/admin/` antes de abrir ventas.

## Base de datos y despliegue
- Migración reproducible: `supabase/migrations/20261127202600_vidaactiva_schema_security.sql`.
- Catálogo reproducible: `supabase/seed.sql` (122 productos; stock inicial 0).
- Las dos Edge Functions están desplegadas en el proyecto enlazado.
- El archivo `index.html` utiliza la URL y publishable key del proyecto.
- Para un entorno nuevo, enlaza el proyecto con Supabase CLI, ejecuta `supabase db push` y despliega las funciones `supabase functions deploy create-order` y `supabase functions deploy submit-payment-proof`. No subas secretos ni archivos `.env`.

## Validación continua
El workflow `.github/workflows/validate-vidaactiva.yml` comprueba la sintaxis de JavaScript y valida las 122 rutas de producto incluidas en el sitemap.

## SEO
Se generaron 122 páginas estáticas de producto bajo `/producto/<slug>/`, con canonical, Open Graph, Twitter Cards y Product JSON-LD. El sitemap incluye el catálogo completo.
