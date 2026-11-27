-- VidaActiva admin authentication, row-level policies and privileges.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create table if not exists public.admin_users (
 user_id uuid primary key references auth.users(id) on delete cascade,
 role text not null default 'admin' check (role in ('admin','manager')),
 created_at timestamptz not null default now()
);
alter table public.admin_users enable row level security;

create or replace function private.is_admin()
returns boolean language sql stable security definer set search_path to ''
as $function$
 select exists(select 1 from public.admin_users a where a.user_id=(select auth.uid()));
$function$;
revoke all on function private.is_admin() from public,anon;
grant execute on function private.is_admin() to authenticated;

drop policy if exists "Admins manage products" on public.products;
create policy "Admins manage products" on public.products for all to authenticated
 using ((select private.is_admin())) with check ((select private.is_admin()));
drop policy if exists "Admins manage orders" on public.orders;
create policy "Admins manage orders" on public.orders for all to authenticated
 using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins manage order items" on public.order_items for all to authenticated
 using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins manage payments" on public.payments for all to authenticated
 using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins read stock movements" on public.stock_movements for select to authenticated
 using ((select private.is_admin()));
create policy "Admins insert stock movements" on public.stock_movements for insert to authenticated
 with check ((select private.is_admin()));
create policy "Admins manage coupons" on public.coupons for all to authenticated
 using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins read admin users" on public.admin_users for select to authenticated
 using (user_id=(select auth.uid()) or (select private.is_admin()));

grant select,insert,update,delete on public.products to authenticated;
grant select,update on public.orders to authenticated;
grant select,insert,update,delete on public.order_items to authenticated;
grant select,insert,update,delete on public.payments to authenticated;
grant select,insert on public.stock_movements to authenticated;
grant select,insert,update,delete on public.coupons to authenticated;
grant select on public.admin_users to authenticated;
