create or replace function public.create_store_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_customer_address text,
  p_notes text,
  p_items jsonb,
  p_idempotency_key uuid
) returns jsonb
language plpgsql security definer set search_path to ''
as $function$
declare
  v_order_id uuid;
  v_order_number bigint;
  v_subtotal numeric(12,2) := 0;
  v_item record;
  v_product public.products%rowtype;
  v_unit_price numeric(12,2);
begin
  if nullif(trim(p_customer_name), '') is null or nullif(trim(p_customer_phone), '') is null
     or nullif(trim(p_customer_address), '') is null then
    raise exception 'Nombre, teléfono y dirección son obligatorios';
  end if;
  if p_idempotency_key is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 100 then
    raise exception 'Pedido inválido';
  end if;
  select id, order_number into v_order_id, v_order_number
    from public.orders where idempotency_key = p_idempotency_key;
  if v_order_id is not null then
    return jsonb_build_object('order_id', v_order_id, 'order_number', v_order_number,
      'status', (select status from public.orders where id=v_order_id),
      'total', (select total from public.orders where id=v_order_id), 'message', 'Pedido ya registrado');
  end if;
  for v_item in
    select x.product_id, sum(x.quantity)::integer as quantity
    from jsonb_to_recordset(p_items) as x(product_id text, quantity integer)
    group by x.product_id order by x.product_id
  loop
    if v_item.product_id is null or v_item.quantity is null or v_item.quantity < 1 or v_item.quantity > 99 then
      raise exception 'Cantidad o producto inválido';
    end if;
    select * into v_product from public.products
      where id = v_item.product_id and active = true for update;
    if not found then raise exception 'Producto no disponible: %', v_item.product_id; end if;
    if v_product.base_price is null or v_product.base_price <= 0 then
      raise exception 'El precio de % está pendiente de revisión.', v_product.product_name;
    end if;
    if v_product.stock < v_item.quantity then
      raise exception 'Stock insuficiente para % (disponible: %)', v_product.product_name, v_product.stock;
    end if;
    v_unit_price := round(v_product.base_price * 2.0, 2);
    v_subtotal := v_subtotal + (v_unit_price * v_item.quantity);
  end loop;
  insert into public.orders(customer_name, customer_phone, customer_email, customer_address, notes, subtotal, total, idempotency_key)
  values(trim(p_customer_name), trim(p_customer_phone), nullif(trim(coalesce(p_customer_email, '')), ''),
    trim(p_customer_address), nullif(trim(coalesce(p_notes, '')), ''), v_subtotal, v_subtotal, p_idempotency_key)
  returning id, order_number into v_order_id, v_order_number;
  for v_item in
    select x.product_id, sum(x.quantity)::integer as quantity
    from jsonb_to_recordset(p_items) as x(product_id text, quantity integer)
    group by x.product_id order by x.product_id
  loop
    select * into v_product from public.products where id = v_item.product_id;
    v_unit_price := round(v_product.base_price * 2.0, 2);
    insert into public.order_items(order_id, product_id, product_name, quantity, unit_price, line_total)
    values(v_order_id, v_product.id, v_product.product_name, v_item.quantity, v_unit_price, v_unit_price * v_item.quantity);
  end loop;
  return jsonb_build_object('order_id', v_order_id, 'order_number', v_order_number, 'status', 'pending_payment', 'total', v_subtotal);
end;
$function$;

create or replace function public.confirm_store_order_payment(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_order public.orders%rowtype;
  v_item record;
  v_product public.products%rowtype;
begin
  if not private.is_admin() then raise exception 'No autorizado'; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  if v_order.status = 'paid_confirmed' then
    return jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number, 'status', v_order.status, 'message', 'El pedido ya estaba confirmado');
  end if;
  if v_order.status not in ('pending_payment','payment_under_review') then
    raise exception 'El pedido no se puede confirmar desde el estado actual';
  end if;
  for v_item in
    select product_id, sum(quantity)::integer as quantity from public.order_items
    where order_id = p_order_id group by product_id order by product_id
  loop
    select * into v_product from public.products where id = v_item.product_id for update;
    if not found or v_product.stock < v_item.quantity then
      raise exception 'Inventario insuficiente para confirmar el pedido. No se descontó ninguna unidad.';
    end if;
  end loop;
  for v_item in
    select product_id, sum(quantity)::integer as quantity from public.order_items
    where order_id = p_order_id group by product_id order by product_id
  loop
    select * into v_product from public.products where id = v_item.product_id for update;
    update public.products set stock = stock - v_item.quantity, updated_at = now() where id = v_item.product_id;
    insert into public.stock_movements(product_id, order_id, movement_type, quantity_change, stock_after, note, created_by)
    values(v_item.product_id, p_order_id, 'sale', -v_item.quantity, v_product.stock - v_item.quantity,
      'Pago verificado del pedido #' || v_order.order_number, auth.uid());
  end loop;
  update public.orders set status = 'paid_confirmed', confirmed_at = now(), updated_at = now() where id = p_order_id;
  update public.payments set status = 'verified', reviewed_at = now(), reviewed_by = auth.uid()
    where order_id = p_order_id and status <> 'verified';
  return jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number, 'status', 'paid_confirmed', 'total', v_order.total);
end;
$function$;

create or replace function public.reject_store_order_payment(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare v_order public.orders%rowtype;
begin
  if not private.is_admin() then raise exception 'No autorizado'; end if;
  update public.orders set status = 'payment_rejected', updated_at = now()
    where id = p_order_id and status in ('pending_payment','payment_under_review') returning * into v_order;
  if not found then raise exception 'Pedido no encontrado o no rechazable'; end if;
  update public.payments set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid()
    where order_id = p_order_id and status <> 'verified';
  return jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number, 'status', 'payment_rejected');
end;
$function$;

create or replace function public.admin_adjust_product_stock(p_product_id text, p_new_stock integer, p_note text default '')
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare v_product public.products%rowtype; v_delta integer; v_type text;
begin
  if not private.is_admin() then raise exception 'No autorizado'; end if;
  if p_new_stock is null or p_new_stock < 0 then raise exception 'El inventario no puede ser negativo'; end if;
  select * into v_product from public.products where id = p_product_id for update;
  if not found then raise exception 'Producto no encontrado'; end if;
  v_delta := p_new_stock - v_product.stock;
  if v_delta = 0 then return jsonb_build_object('product_id', p_product_id, 'stock', p_new_stock, 'changed', false); end if;
  v_type := case when v_delta > 0 then 'restock' else 'adjustment' end;
  update public.products set stock = p_new_stock, updated_at = now() where id = p_product_id;
  insert into public.stock_movements(product_id, movement_type, quantity_change, stock_after, note, created_by)
  values(p_product_id, v_type, v_delta, p_new_stock, coalesce(nullif(trim(p_note), ''), 'Ajuste manual de inventario'), auth.uid());
  return jsonb_build_object('product_id', p_product_id, 'stock', p_new_stock, 'changed', true);
end;
$function$;

revoke all on function public.confirm_store_order_payment(uuid) from public, anon;
grant execute on function public.confirm_store_order_payment(uuid) to authenticated;
revoke all on function public.reject_store_order_payment(uuid) from public, anon;
grant execute on function public.reject_store_order_payment(uuid) to authenticated;
revoke all on function public.admin_adjust_product_stock(text,integer,text) from public, anon;
grant execute on function public.admin_adjust_product_stock(text,integer,text) to authenticated;
revoke all on function public.create_store_order(text,text,text,text,text,jsonb,uuid) from public;
grant execute on function public.create_store_order(text,text,text,text,text,jsonb,uuid) to anon, authenticated;

drop policy if exists "Admins manage orders" on public.orders;
drop policy if exists "Admins read orders" on public.orders;
create policy "Admins read orders" on public.orders for select to authenticated using ((select private.is_admin()));
create policy "Admins update orders" on public.orders for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()));
drop policy if exists "Admins manage products" on public.products;
drop policy if exists "Public can read active products" on public.products;
create policy "Public and admins read products" on public.products for select to anon, authenticated using (active = true or (select private.is_admin()));
create policy "Admins insert products" on public.products for insert to authenticated with check ((select private.is_admin()));
create policy "Admins update products" on public.products for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins delete products" on public.products for delete to authenticated using ((select private.is_admin()));

create index if not exists idx_order_items_product_id on public.order_items(product_id);
create index if not exists idx_payments_reviewed_by on public.payments(reviewed_by);
create index if not exists idx_stock_movements_order_id on public.stock_movements(order_id);
create index if not exists idx_stock_movements_created_by on public.stock_movements(created_by);
