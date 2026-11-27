-- VidaActiva core schema and catalog seed (122 products).
create extension if not exists pgcrypto;
create table if not exists public.products (
 id text primary key,
 category text not null default '',
 product_name text not null,
 presentation_lab text not null default '',
 base_price numeric(12,2) not null check (base_price >= 0),
 description text not null default '',
 image_file text,
 slug text not null unique,
 active boolean not null default true,
 stock integer not null default 0 check (stock >= 0),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.orders (
 id uuid primary key default gen_random_uuid(),
 order_number bigint generated always as identity unique,
 status text not null default 'pending_payment'
   check (status in ('pending_payment','payment_under_review','paid_confirmed','payment_rejected','cancelled','stock_issue')),
 customer_name text not null,
 customer_phone text not null,
 customer_email text,
 customer_address text,
 notes text,
 subtotal numeric(12,2) not null check (subtotal >= 0),
 total numeric(12,2) not null check (total >= 0),
 currency text not null default 'USD',
 idempotency_key uuid not null unique,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 confirmed_at timestamptz
);
create table if not exists public.order_items (
 id bigint generated always as identity primary key,
 order_id uuid not null references public.orders(id) on delete cascade,
 product_id text not null references public.products(id),
 product_name text not null,
 quantity integer not null check (quantity > 0),
 unit_price numeric(12,2) not null check (unit_price >= 0),
 line_total numeric(12,2) not null check (line_total >= 0)
);
create table if not exists public.payments (
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null references public.orders(id) on delete cascade,
 method text not null default 'manual',
 reference text,
 proof_url text,
 status text not null default 'submitted' check (status in ('submitted','verified','rejected')),
 reviewed_by uuid references auth.users(id),
 reviewed_at timestamptz,
 created_at timestamptz not null default now()
);
create table if not exists public.stock_movements (
 id bigint generated always as identity primary key,
 product_id text not null references public.products(id),
 order_id uuid references public.orders(id),
 movement_type text not null check (movement_type in ('initial','restock','sale','adjustment','reversal')),
 quantity_change integer not null,
 stock_after integer not null check (stock_after >= 0),
 note text,
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create table if not exists public.coupons (
 code text primary key,
 discount_percent numeric(5,2) not null check (discount_percent > 0 and discount_percent <= 100),
 active boolean not null default true,
 expires_at timestamptz,
 created_at timestamptz not null default now()
);
create index if not exists idx_products_active_name on public.products(active, product_name);
create index if not exists idx_orders_status_created on public.orders(status, created_at desc);
create index if not exists idx_order_items_order on public.order_items(order_id);
create index if not exists idx_payments_order on public.payments(order_id);
create index if not exists idx_stock_movements_product on public.stock_movements(product_id, created_at desc);

alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.payments enable row level security;
alter table public.stock_movements enable row level security;
alter table public.coupons enable row level security;

drop policy if exists "Public can read active products" on public.products;
create policy "Public can read active products" on public.products for select to anon, authenticated using (active = true);
grant select on public.products to anon, authenticated;

create or replace function public.create_store_order(
 p_customer_name text,p_customer_phone text,p_customer_email text,p_customer_address text,
 p_notes text,p_items jsonb,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
 v_order_id uuid; v_order_number bigint; v_subtotal numeric(12,2):=0;
 v_item record; v_product public.products%rowtype; v_unit_price numeric(12,2);
begin
 if nullif(trim(p_customer_name),'') is null or nullif(trim(p_customer_phone),'') is null
   or nullif(trim(p_customer_address),'') is null then raise exception 'Nombre, teléfono y dirección son obligatorios'; end if;
 if p_idempotency_key is null or jsonb_typeof(p_items)<>'array'
   or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>100 then raise exception 'Pedido inválido'; end if;
 select id,order_number into v_order_id,v_order_number from public.orders where idempotency_key=p_idempotency_key;
 if v_order_id is not null then return jsonb_build_object('order_id',v_order_id,'order_number',v_order_number,
   'status',(select status from public.orders where id=v_order_id),'total',(select total from public.orders where id=v_order_id)); end if;
 for v_item in select x.product_id,sum(x.quantity)::integer quantity from jsonb_to_recordset(p_items) as x(product_id text,quantity integer) group by x.product_id order by x.product_id loop
   if v_item.product_id is null or v_item.quantity is null or v_item.quantity<1 or v_item.quantity>99 then raise exception 'Cantidad o producto inválido'; end if;
   select * into v_product from public.products where id=v_item.product_id and active=true for update;
   if not found then raise exception 'Producto no disponible: %',v_item.product_id; end if;
   if v_product.base_price<=0 then raise exception 'El precio de % está pendiente de revisión.',v_product.product_name; end if;
   if v_product.stock<v_item.quantity then raise exception 'Stock insuficiente para % (disponible: %)',v_product.product_name,v_product.stock; end if;
   v_unit_price:=round(v_product.base_price*2.0,2); v_subtotal:=v_subtotal+(v_unit_price*v_item.quantity);
 end loop;
 insert into public.orders(customer_name,customer_phone,customer_email,customer_address,notes,subtotal,total,idempotency_key)
 values(trim(p_customer_name),trim(p_customer_phone),nullif(trim(coalesce(p_customer_email,'')),''),trim(p_customer_address),
   nullif(trim(coalesce(p_notes,'')),''),v_subtotal,v_subtotal,p_idempotency_key)
 returning id,order_number into v_order_id,v_order_number;
 for v_item in select x.product_id,sum(x.quantity)::integer quantity from jsonb_to_recordset(p_items) as x(product_id text,quantity integer) group by x.product_id order by x.product_id loop
   select * into v_product from public.products where id=v_item.product_id;
   v_unit_price:=round(v_product.base_price*2.0,2);
   insert into public.order_items(order_id,product_id,product_name,quantity,unit_price,line_total)
   values(v_order_id,v_product.id,v_product.product_name,v_item.quantity,v_unit_price,v_unit_price*v_item.quantity);
 end loop;
 return jsonb_build_object('order_id',v_order_id,'order_number',v_order_number,'status','pending_payment','total',v_subtotal);
end;
$function$;
revoke all on function public.create_store_order(text,text,text,text,text,jsonb,uuid) from public;
grant execute on function public.create_store_order(text,text,text,text,text,jsonb,uuid) to anon,authenticated;

insert into public.products(id,category,product_name,presentation_lab,base_price,description,image_file,slug,stock,active)
values
('1','LAB. FITOSANA','ARANDANO ROJO X 60 TAB','TABLETAS',6.00,'Ayuda a prevenir infecciones urinarias y mejora la salud de la vejiga gracias a sus propiedades antioxidantes.','arandanorojo.jpg','arandano-rojo-x-60-tab-1',0,true),
('2','LAB. FITOSANA','ASHWANGANDHA X 60 TAB','TABLETAS',7.00,'Reduce el estrés y la ansiedad, mejora la energía y la concentración. Adaptógeno natural.','ashwagandha.jpg','ashwangandha-x-60-tab-2',0,true),
('3','LAB. FITOSANA','CARDO LECHOZO X 60 TAB','TABLETAS',6.00,'Protege el hígado, estimula la regeneración celular y mejora la digestión de grasas.','cardolechoso.jpg','cardo-lechozo-x-60-tab-3',0,true),
('4','LAB. FITOSANA','CASTAÑO DE INDIAS X 60 TAB','TABLETAS',6.00,'Mejora la circulación sanguínea, reduce várices y la sensación de piernas cansadas.','castañodeindias.jpg','castano-de-indias-x-60-tab-4',0,true),
('5','LAB. FITOSANA','CENTELLA ASIATICA X 60 TAB','TABLETAS',6.00,'Estimula la producción de colágeno, mejora la piel y acelera la cicatrización.','centellasiatica.jpg','centella-asiatica-x-60-tab-5',0,true),
('6','LAB. FITOSANA','CHANCA PIEDRA X 60 TAB','TABLETAS',6.00,'Ayuda a eliminar cálculos renales y biliares de forma natural. Diurética.','chancapiedra.jpg','chanca-piedra-x-60-tab-6',0,true),
('7','LAB. FITOSANA','ESPIRULINA X 60 TAB','TABLETAS',6.00,'Alga rica en proteínas, vitaminas y minerales. Aumenta la energía y fortalece el sistema inmune.','espirulina.jpg','espirulina-x-60-tab-7',0,true),
('8','LAB. FITOSANA','GINKGO BILOBA X 60 TAB','TABLETAS',6.00,'Mejora la memoria, la concentración y la circulación cerebral. Antioxidante natural.','Ginkgo Biloba.png','ginkgo-biloba-x-60-tab-8',0,true),
('9','LAB. FITOSANA','ACIDO FOLICO X 60 TAB','TABLETAS',6.00,'Esencial para mujeres embarazadas, previene defectos del tubo neural. Mejora la producción de glóbulos rojos.','Acido Folico.png','acido-folico-x-60-tab-9',0,true),
('10','LAB. FITOSANA','BIOTINA X 60 TAB','TABLETAS',6.00,'Fortalece el cabello, las uñas y la piel. Mejora el metabolismo de grasas y proteínas.','Biotina.png','biotina-x-60-tab-10',0,true),
('11','LAB. FITOSANA','CALOSTRO BOVINO X 60 TAB','TABLETAS',6.00,'Fortalece el sistema inmunológico, mejora la digestión y acelera la recuperación muscular.','Calostro Bovino.png','calostro-bovino-x-60-tab-11',0,true),
('12','LAB. FITOSANA','CENTRUNEX X 60 TAB','TABLETAS',6.00,'Multivitamínico completo para la salud general. Aporta energía y vitalidad diaria.','Centrunex.png','centrunex-x-60-tab-12',0,true),
('13','LAB. FITOSANA','CENTRUNEX MAN X 60 TAB','TABLETAS',6.00,'Fórmula especial para hombres. Mejora la energía, el rendimiento físico y la salud prostática.','Centrunex Man.png','centrunex-man-x-60-tab-13',0,true),
('14','LAB. FITOSANA','CENTRUNEX SILVER X 60 TAB','TABLETAS',6.00,'Multivitamínico para adultos mayores. Fortalece huesos, memoria y sistema inmunológico.','Centrunex Silver.png','centrunex-silver-x-60-tab-14',0,true),
('15','LAB. FITOSANA','CENTRUNEX WOMAN X 60 TAB','TABLETAS',6.00,'Fórmula especial para mujeres. Equilibrio hormonal, belleza de piel y energía natural.','Centrunex Woman.png','centrunex-woman-x-60-tab-15',0,true),
('16','LAB. FITOSANA','CITRATO MAGNESIO X 60 TAB','TABLETAS',6.00,'Relaja los músculos, mejora el sueño y combate el estreñimiento. Esencial para el sistema nervioso.','citratodemagnesio.png','citrato-magnesio-x-60-tab-16',0,true),
('17','LAB. FITOSANA','CITRATO MAGNESIO X 120 TAB','TABLETAS',10.20,'Presentación económica. Relaja músculos, mejora el sueño y combate el estreñimiento.','Citrato de Magnesio 120tab.png','citrato-magnesio-x-120-tab-17',0,true),
('18','LAB. FITOSANA','CITRA. MAGNESIO + ZINC X 60 TAB','TABLETAS',6.00,'Magnesio con Zinc para fortalecer el sistema inmune y mejorar la salud de la piel.','Magnesio + Zinc.png','citra-magnesio-zinc-x-60-tab-18',0,true),
('19','LAB. FITOSANA','CITRA. MAGNESIO + VIT. C X 60 TAB','TABLETAS',6.00,'Combinación antioxidante que fortalece defensas y reduce el cansancio.','Magnesio + Vitamina C.png','citra-magnesio-vit-c-x-60-tab-19',0,true),
('20','LAB. FITOSANA','CITRA. MAGNESIO + HIERRO X 60 TAB','TABLETAS',6.00,'Ideal para combatir la anemia y la fatiga. Mejora la energía y el rendimiento físico.','Hierro+Magnesio.png','citra-magnesio-hierro-x-60-tab-20',0,true),
('21','LAB. FITOSANA','CITRA. MAGNE. + POTASIO X 60 TAB','TABLETAS',6.00,'Previene calambres musculares y mejora la función cardiovascular.','Magnesio + Potasio.png','citra-magne-potasio-x-60-tab-21',0,true),
('22','LAB. FITOSANA','CITRA. MAGNESIO + VIT B6 X 60 TAB','TABLETAS',6.00,'Reduce el estrés, la ansiedad y mejora el estado de ánimo.','Magnesio + Vitamina B6.png','citra-magnesio-vit-b6-x-60-tab-22',0,true),
('23','LAB. FITOSANA','CITRATO DE POTASIO X 60 TAB','TABLETAS',6.00,'Regula la presión arterial y previene calambres musculares.','Citrato de Potasio.png','citrato-de-potasio-x-60-tab-23',0,true),
('24','LAB. FITOSANA','CITRATO DE ZINC X 60 TAB','TABLETAS',6.00,'Fortalece el sistema inmune, mejora la salud de la piel y el cabello.','Citrato de Zinc.png','citrato-de-zinc-x-60-tab-24',0,true),
('25','LAB. FITOSANA','COLAGENO HIDROLIZADO X 60 TAB','TABLETAS',6.00,'Mejora la elasticidad de la piel, fortalece articulaciones y huesos.','Colageno.png','colageno-hidrolizado-x-60-tab-25',0,true),
('26','LAB. FITOSANA','COLÁGENO C/ELASTINA X 60 TAB','TABLETAS',6.00,'Combate los signos del envejecimiento, mejora firmeza y elasticidad de la piel.','Colageno con elastina.png','colageno-c-elastina-x-60-tab-26',0,true),
('27','LAB. FITOSANA','COLÁGENO C/VIT. C X 60 TAB','TABLETAS',6.00,'Vitamina C potencia la absorción del colágeno para una piel más saludable.','Colageno + vitamina c.png','colageno-c-vit-c-x-60-tab-27',0,true),
('28','LAB. FITOSANA','COLAGENO POLVO 500 GR.','POLVO',17.19,'Colágeno hidrolizado en polvo. Ideal para preparar batidos. Piel, articulaciones y huesos.','Colageno.png','colageno-polvo-500-gr-28',0,true),
('29','LAB. FITOSANA','COMPLEJO B-VITAMINAS X 60 TAB','TABLETAS',6.00,'Todas las vitaminas del complejo B. Energía, metabolismo y sistema nervioso.','Complejo B.png','complejo-b-vitaminas-x-60-tab-29',0,true),
('30','LAB. FITOSANA','CREATINA MONOHIDRAT X 60 TAB','TABLETAS',6.00,'Aumenta la fuerza y el rendimiento deportivo. Mejora la recuperación muscular.','creatinamonohidratada.png','creatina-monohidrat-x-60-tab-30',0,true),
('31','LAB. FITOSANA','CREATINA MONOHIDRAT 500 GR.','POLVO',17.00,'Creatina en polvo para mayor rendimiento deportivo y ganancia muscular.','Creatina.png','creatina-monohidrat-500-gr-31',0,true),
('32','LAB. FITOSANA','GLUTAMINA + CREATINA X 60 TAB','TABLETAS',6.00,'Combinación sinérgica para aumentar masa muscular y acelerar recuperación.','Glucosamina Condroitina.png','glutamina-creatina-x-60-tab-32',0,true),
('33','LAB. FITOSANA','L-ARGININA X 60 TAB','TABLETAS',6.00,'Mejora la circulación, el rendimiento deportivo y la función sexual.','L-Arginina.png','l-arginina-x-60-tab-33',0,true),
('34','LAB. FITOSANA','L-CARNITINA X 60 TAB','TABLETAS',6.00,'Ayuda a quemar grasas, aumenta la energía y mejora el rendimiento deportivo.','lcarnitina.png','l-carnitina-x-60-tab-34',0,true),
('35','LAB. FITOSANA','LEVADURA DE CERVEZA X 60 TAB','TABLETAS',6.00,'Rica en vitaminas del grupo B. Mejora la piel, el cabello y las uñas.','Levadura de Cerveza.png','levadura-de-cerveza-x-60-tab-35',0,true),
('36','LAB. FITOSANA','NAD+ X 60 TAB','TABLETAS',6.00,'Retrasa el envejecimiento celular, mejora la energía y la reparación del ADN.','Nad+.png','nad-x-60-tab-36',0,true),
('37','LAB. FITOSANA','NIACINA X 60 TAB','TABLETAS',6.00,'Vitamina B3. Reduce el colesterol malo y mejora la circulación.','Vibaxina.png','niacina-x-60-tab-37',0,true),
('38','LAB. FITOSANA','SELENIO X 60 TAB','TABLETAS',6.00,'Potente antioxidante. Protege las células del daño oxidativo.','Selenio.png','selenio-x-60-tab-38',0,true),
('39','LAB. FITOSANA','VIBAXINA X 60 TAB','TABLETAS',6.00,'Mejora el estado de ánimo, reduce la ansiedad y el estrés.','Vibaxina.png','vibaxina-x-60-tab-39',0,true),
('40','LAB. FITOSANA','VINAGRE MANZANA X 60 TAB','TABLETAS',6.00,'Ayuda a controlar el peso, mejora la digestión y regula el azúcar en sangre.','Vinagre de Manzana.png','vinagre-manzana-x-60-tab-40',0,true),
('41','LAB. FITOSANA','VITAMINA C X 60 TAB','TABLETAS',6.00,'Fortalece el sistema inmunológico, antioxidante y mejora la absorción del hierro.','Vitamina C.png','vitamina-c-x-60-tab-41',0,true),
('42','LAB. FITOSANA','VITAMINA D3 X 60 TAB','TABLETAS',6.00,'Fortalece los huesos y mejora el sistema inmunológico. Vital para la salud ósea.','Vitamina D3.png','vitamina-d3-x-60-tab-42',0,true),
('43','LAB. FITOSANA','VITAMINAS D3 + K2 X 60 TAB','TABLETAS',6.00,'Sinergia para una mejor absorción del calcio. Protege huesos y arterias.','Vitamina D3+K2.png','vitaminas-d3-k2-x-60-tab-43',0,true),
('44','LAB. FITOSANA','WHEY HUEVO VAINILLA 500 GR.','POLVO',13.00,'Proteína de huevo en polvo sabor vainilla. Ideal para aumentar masa muscular.',null,'whey-huevo-vainilla-500-gr-44',0,true),
('45','LAB. FITOSANA','WHEY HUEVO VAINILLA 907 GR.','POLVO',20.00,'Proteína de huevo en polvo sabor vainilla. Presentación económica.',null,'whey-huevo-vainilla-907-gr-45',0,true),
('46','LAB. FITOSANA','WHEY HUEVO CHOCOLATE 500 GR.','POLVO',13.00,'Proteína de huevo en polvo sabor chocolate. Excelente para recuperación muscular.',null,'whey-huevo-chocolate-500-gr-46',0,true),
('47','LAB. FITOSANA','WHEY HUEVO CHOCOLATE 907 GR.','POLVO',0.00,'Proteína de huevo en polvo sabor chocolate. Presentación económica.',null,'whey-huevo-chocolate-907-gr-47',0,true),
('48','LAB. FITOSANA','WHEY NITRO VAINILLA 907 GR.','POLVO',20.00,'Proteína avanzada con aminoácidos. Máxima recuperación y crecimiento muscular.',null,'whey-nitro-vainilla-907-gr-48',0,true),
('49','LAB. FITOSANA','WHEY PROTEIN VAINILLA 500 GR.','POLVO',13.00,'Proteína de suero de leche sabor vainilla. Ideal para deportistas.',null,'whey-protein-vainilla-500-gr-49',0,true),
('50','LAB. FITOSANA','WHEY PROTEIN VAINILLA 907 GR.','POLVO',20.00,'Proteína de suero de leche sabor vainilla. Presentación económica.',null,'whey-protein-vainilla-907-gr-50',0,true),
('51','LAB. FITOSANA','WHEY PROTEIN CHOCOLATE 500 GR.','POLVO',13.00,'Proteína de suero de leche sabor chocolate. Excelente sabor y textura.',null,'whey-protein-chocolate-500-gr-51',0,true),
('52','LAB. FITOSANA','WHEY PROTEIN CHOCOLATE 907 GR.','POLVO',20.00,'Proteína de suero de leche sabor chocolate. Presentación económica.',null,'whey-protein-chocolate-907-gr-52',0,true),
('53','LAB. FITOSANA','ARANDANO NEGRO X 60 TAB','TABLETAS',6.00,'Mejora la visión nocturna y protege la salud ocular gracias a sus antocianinas.','Arandano Negro.png','arandano-negro-x-60-tab-53',0,true),
('54','LAB. FITOSANA','BERBERINA X 60 TAB','TABLETAS',7.00,'Regula el azúcar en sangre y mejora el metabolismo de las grasas.',null,'berberina-x-60-tab-54',0,true),
('55','LAB. FITOSANA','BOLDO X 60 TAB','TABLETAS',6.00,'Mejora la digestión, protege el hígado y alivia los cólicos hepáticos.',null,'boldo-x-60-tab-55',0,true),
('56','LAB. FITOSANA','CARBON ACTIVADO X 60 TAB','TABLETAS',6.00,'Absorbe toxinas y gases. Alivia la hinchazón y la indigestión.','Carbon Activado.png','carbon-activado-x-60-tab-56',0,true),
('57','LAB. FITOSANA','CARIBE (OMEGA 3-6-9) X 60 TAB','TABLETAS',6.00,'Ácidos grasos esenciales para la salud cardiovascular y cerebral.','Caribe con Omega 369.png','caribe-omega-3-6-9-x-60-tab-57',0,true),
('58','LAB. FITOSANA','CARTILAGO TIBURON X 60 TAB','TABLETAS',6.00,'Fortalece las articulaciones y previene el desgaste del cartílago.','Cartilago de Tiburon.png','cartilago-tiburon-x-60-tab-58',0,true),
('59','LAB. FITOSANA','CARTILAGO/UÑA DE GATO X 60 TAB','TABLETAS',6.00,'Antiinflamatorio natural para articulaciones. Fortalece el sistema inmune.','cartilagouñadegato.jpg','cartilago-una-de-gato-x-60-tab-59',0,true),
('60','LAB. FITOSANA','CASCARA SAGRADA X 60 TAB','TABLETAS',6.00,'Laxante natural para el estreñimiento ocasional. Limpia el colon.','cascarasagrada.jpg','cascara-sagrada-x-60-tab-60',0,true),
('61','LAB. FITOSANA','CIRCULACIÓN X 60 TAB','TABLETAS',6.00,'Mejora la circulación sanguínea, previene várices y piernas cansadas.','Circulacion.png','circulacion-x-60-tab-61',0,true),
('62','LAB. FITOSANA','CITR. MAG+MELATONINA X 60 TAB','TABLETAS',6.00,'Mejora la calidad del sueño y relaja los músculos. Ideal para el insomnio.','Magnesio + Melatonina.png','citr-mag-melatonina-x-60-tab-62',0,true),
('63','LAB. FITOSANA','CITRATO CALCIO X 60 TAB','TABLETAS',6.00,'Fortalece huesos y dientes. Previene la osteoporosis.','Citrato de Calcio con Vitamina D.png','citrato-calcio-x-60-tab-63',0,true),
('64','LAB. FITOSANA','COLA DE CABALLO X 60 TAB','TABLETAS',6.00,'Diurético natural. Ayuda a eliminar líquidos y fortalecer uñas y cabello.','coladecaballo.png','cola-de-caballo-x-60-tab-64',0,true),
('65','LAB. FITOSANA','COLON CLEAN X 60 TAB','TABLETAS',6.00,'Limpieza profunda del colon. Elimina toxinas y mejora la digestión.','Colon clean.png','colon-clean-x-60-tab-65',0,true),
('66','LAB. FITOSANA','CURCUMA-JENGIBRE X 60 TAB','TABLETAS',6.00,'Antiinflamatorio natural. Alivia dolores articulares y mejora la digestión.','curcumayjengibre.jpg','curcuma-jengibre-x-60-tab-66',0,true),
('67','LAB. FITOSANA','CURCUMA-JENJIBRE-PIMIENTA X 60 TAB','TABLETAS',6.00,'Pimienta negra potencia la absorción de la cúrcuma. Máximo efecto antiinflamatorio.','Curcuma con Jengibre + Pimienta Negra + Vitamina C.png','curcuma-jenjibre-pimienta-x-60-tab-67',0,true),
('68','LAB. FITOSANA','DULCES SUEÑOS X 60 TAB','TABLETAS',6.00,'Mejora la calidad del sueño de forma natural. Reduce el insomnio.','Dulce Sueno.png','dulces-suenos-x-60-tab-68',0,true),
('69','LAB. FITOSANA','ECHINACEA X 60 TAB','TABLETAS',6.00,'Fortalece el sistema inmunológico. Previene y combate resfriados.','Echinacea.png','echinacea-x-60-tab-69',0,true),
('70','LAB. FITOSANA','ESCOBA DE CARNICERO X 60 TAB','TABLETAS',6.00,'Mejora la circulación y alivia la insuficiencia venosa.','Escoba de Carnicero.png','escoba-de-carnicero-x-60-tab-70',0,true),
('71','LAB. FITOSANA','FENOGRECO X 60 TAB','TABLETAS',6.00,'Aumenta la producción de leche materna y mejora la digestión.','Fenogreco.png','fenogreco-x-60-tab-71',0,true),
('72','LAB. FITOSANA','GINSENG KOREANO X 60 TAB','TABLETAS',6.00,'Aumenta la energía física y mental. Mejora el rendimiento sexual.','Ginseng Koreano.png','ginseng-koreano-x-60-tab-72',0,true),
('73','LAB. FITOSANA','GLICINATO MAGNESIO X 60 TAB','TABLETAS',6.00,'Alta absorción. Reduce el estrés, mejora el sueño y relaja los músculos.','glicinato.png','glicinato-magnesio-x-60-tab-73',0,true),
('74','LAB. FITOSANA','GLUCOSAMIN/COINDRITIN X 60 TAB','TABLETAS',6.00,'Regenera el cartílago y alivia el dolor articular.','Glucosamina Condroitina.png','glucosamin-coindritin-x-60-tab-74',0,true),
('75','LAB. FITOSANA','GLUCOSAMINA X 60 TAB','TABLETAS',6.00,'Fortalece las articulaciones y previene el desgaste óseo.','Glucosamina.png','glucosamina-x-60-tab-75',0,true),
('76','LAB. FITOSANA','GLUTAMINA X 60 TAB','TABLETAS',6.00,'Acelera la recuperación muscular y mejora la salud intestinal.','L-Glutamina.png','glutamina-x-60-tab-76',0,true),
('77','LAB. FITOSANA','GRAVIOLA X 60 TAB','TABLETAS',6.00,'Propiedades antioxidantes y antiinflamatorias. Apoyo al sistema inmune.',null,'graviola-x-60-tab-77',0,true),
('78','LAB. FITOSANA','HIERRO X 60 TAB','TABLETAS',6.00,'Combate la anemia y la fatiga. Mejora la producción de glóbulos rojos.','Hierro.png','hierro-x-60-tab-78',0,true),
('79','LAB. FITOSANA','INOSITOL X 60 TAB','TABLETAS',6.00,'Mejora la salud metabólica y reduce la ansiedad. Beneficioso para SOP.',null,'inositol-x-60-tab-79',0,true),
('80','LAB. FITOSANA','L-LUTEINA X 60 TAB','TABLETAS',6.00,'Protege la salud ocular y previene la degeneración macular.','L-Luteina.png','l-luteina-x-60-tab-80',0,true),
('81','LAB. FITOSANA','LOCHITA X 60 TAB','TABLETAS',6.00,'Ayuda a controlar el acné y mejorar la salud de la piel.','Lochita.png','lochita-x-60-tab-81',0,true),
('82','LAB. FITOSANA','MACA X 60 TAB','TABLETAS',6.00,'Aumenta la energía, la fertilidad y el deseo sexual.',null,'maca-x-60-tab-82',0,true),
('83','LAB. FITOSANA','MACHO VIRIL X 60 TAB','TABLETAS',6.00,'Mejora el rendimiento sexual masculino y la vitalidad.','Macho Viril.png','macho-viril-x-60-tab-83',0,true),
('84','LAB. FITOSANA','MAPURITE X 60 TAB','TABLETAS',6.00,'Regula los niveles de azúcar en sangre de forma natural.','Mapurite.png','mapurite-x-60-tab-84',0,true),
('85','LAB. FITOSANA','MORINGA X 60 TAB','TABLETAS',6.00,'Superalimento rico en vitaminas y minerales. Antioxidante natural.','moringa.jpg','moringa-x-60-tab-85',0,true),
('86','LAB. FITOSANA','OMEGA 3 X 30 SOFTGELS','SOFTGELS',6.00,'Salud cardiovascular y cerebral. Reduce la inflamación.','omega3.jpg','omega-3-x-30-softgels-86',0,true),
('87','LAB. FITOSANA','NAD 400 MG X 30 SOFTGELS','SOFTGELS',9.00,'Retrasa el envejecimiento celular y mejora la energía.','Nad+ 30 Softgel.png','nad-400-mg-x-30-softgels-87',0,true),
('88','LAB. FITOSANA','NAD+ RESVERATROL 400 MG X 30 SOFTGELS','SOFTGELS',7.00,'Sinergia antioxidante. Protege las células del envejecimiento.','Resveratrol + Nad+ 30 Softgel.png','nad-resveratrol-400-mg-x-30-softgels-88',0,true),
('89','LAB. FITOSANA','RESVERATROL 400 MG X 30 SOFTGELS','SOFTGELS',7.00,'Antioxidante que protege el corazón y retrasa el envejecimiento.','Resveratrol 30 Softgel.png','resveratrol-400-mg-x-30-softgels-89',0,true),
('90','LAB. FITOSANA','ÑAME SALVAJE X 60 TAB','TABLETAS',6.00,'Ayuda a controlar la diabetes y mejora la salud metabólica.','ñamesalvaje.jpg','name-salvaje-x-60-tab-90',0,true),
('91','LAB. FITOSANA','OREGANO X 60 TAB','TABLETAS',6.00,'Antibiótico natural. Combate infecciones y parásitos.','oregano.jpg','oregano-x-60-tab-91',0,true),
('92','LAB. FITOSANA','PALO DE ARCO X 60 TAB','TABLETAS',6.00,'Antifúngico y antibacteriano natural. Fortalece las defensas.','Una de Gato.png','palo-de-arco-x-60-tab-92',0,true),
('93','LAB. FITOSANA','PIÑA-LINAZA-SABILA X 60 TAB','TABLETAS',6.00,'Depurativo natural. Ayuda a la pérdida de peso y mejora la digestión.','Pira Ginkgo Biloba.png','pina-linaza-sabila-x-60-tab-93',0,true),
('94','LAB. FITOSANA','PIRA X 60 TAB','TABLETAS',6.00,'Controla el apetito y ayuda en la pérdida de peso.','pira.jpg','pira-x-60-tab-94',0,true),
('95','LAB. FITOSANA','PIRA CON GINKGO X 60 TAB','TABLETAS',6.00,'Ayuda a controlar el peso y mejora la circulación cerebral.','piraginko.jpg','pira-con-ginkgo-x-60-tab-95',0,true),
('96','LAB. FITOSANA','PROSTASANA X 60 TAB','TABLETAS',6.00,'Mejora la salud de la próstata y la función urinaria.','prostasana.jpg','prostasana-x-60-tab-96',0,true),
('97','LAB. FITOSANA','QUINCHONCHO X 60 TAB','TABLETAS',6.00,'Ayuda a controlar los niveles de colesterol y triglicéridos.','quinchoncho.jpg','quinchoncho-x-60-tab-97',0,true),
('98','LAB. FITOSANA','QUISTE GINOL X 60 TAB','TABLETAS',6.00,'Ayuda a reducir quistes ováricos y desequilibrios hormonales.','Quiste Ginol.png','quiste-ginol-x-60-tab-98',0,true),
('99','LAB. FITOSANA','RESVERATROL X 60 TAB','TABLETAS',6.00,'Potente antioxidante que protege el corazón y retrasa el envejecimiento.','Resveratrol.png','resveratrol-x-60-tab-99',0,true),
('100','LAB. FITOSANA','SABILA CON LINAZA X 60 TAB','TABLETAS',6.00,'Mejora la digestión y la salud intestinal. Regula el tránsito.','Sabila con Linaza.png','sabila-con-linaza-x-60-tab-100',0,true),
('101','LAB. FITOSANA','SAW PALMETTO X 60 TAB','TABLETAS',6.00,'Salud prostática y prevención de la caída del cabello.','Saw Palmetto.png','saw-palmetto-x-60-tab-101',0,true),
('102','LAB. FITOSANA','TE VERDE X 60 TAB','TABLETAS',6.00,'Acelera el metabolismo y ayuda a quemar grasas. Antioxidante.','Te Verde.png','te-verde-x-60-tab-102',0,true),
('103','LAB. FITOSANA','TUMBA BARRIGA X 60 TAB','TABLETAS',6.00,'Ayuda a reducir la grasa abdominal de forma natural.','Tumba Barriga.png','tumba-barriga-x-60-tab-103',0,true),
('104','LAB. FITOSANA','UÑA DE GATO X 60 TAB','TABLETAS',6.00,'Antiinflamatorio natural para artritis y problemas articulares.','Una de Gato.png','una-de-gato-x-60-tab-104',0,true),
('105','LAB. FITOSANA','VALERIANA X 60 TAB','TABLETAS',6.00,'Relajante natural. Mejora el sueño y reduce la ansiedad.','Valeriana.png','valeriana-x-60-tab-105',0,true),
('106','LAB. FITOSANA','BIOTINA SOFT X 60 TAB','TABLETAS',6.00,'Fortalece el cabello, las uñas y la piel.','Biotina 30 Softgel.png','biotina-soft-x-60-tab-106',0,true),
('107','LAB. FITOSANA','OMEGA 3-6-9 X 60 TAB','TABLETAS',6.00,'Ácidos grasos esenciales para el corazón, cerebro y articulaciones.','omega369.jpg','omega-3-6-9-x-60-tab-107',0,true),
('108','LAB. FITOSANA','VITAMINA E 1000 UI X 60 TAB','TABLETAS',7.00,'Potente antioxidante para la piel y el sistema cardiovascular.','Vitamina E 1000 IU.png','vitamina-e-1000-ui-x-60-tab-108',0,true),
('109','LAB. FITOSANA','VITAMINA B1-TIAMINA X 60 TAB','TABLETAS',6.00,'Mejora el metabolismo energético y la función nerviosa.','Vitamina B1-Tiamina.png','vitamina-b1-tiamina-x-60-tab-109',0,true),
('110','LAB. FITOSANA','VITAMINA B12-CIANOCOBALAMINA X 60 TAB','TABLETAS',6.00,'Esencial para la formación de glóbulos rojos y el sistema nervioso.','Vitamina B1-Tiamina.png','vitamina-b12-cianocobalamina-x-60-tab-110',0,true),
('111','LAB. FITOSANA','VITAMINA B2-RIBOFLAVINA X 60 TAB','TABLETAS',6.00,'Importante para la producción de energía y la salud ocular.','Vitamina B2.png','vitamina-b2-riboflavina-x-60-tab-111',0,true),
('112','LAB. FITOSANA','ADELGAZANTE 4 EN 1 X 60 TAB','TABLETAS',6.00,'Fórmula completa para apoyar la pérdida de peso.','Adelgazante 4en1.png','adelgazante-4-en-1-x-60-tab-112',0,true),
('113','LAB. FITOSANA','5-HTP X 60 TAB','TABLETAS',6.00,'Mejora el estado de ánimo, reduce la ansiedad y el insomnio.','5HTP.png','5-htp-x-60-tab-113',0,true),
('114','LAB. FITOSANA','ACIDO PHILUS X 60 TAB','TABLETAS',6.00,'Mejora la digestión y la absorción de nutrientes.','Acidophilus.png','acido-philus-x-60-tab-114',0,true),
('115','LAB. FITOSANA','AGUAJE X 60 TAB','TABLETAS',6.00,'Mejora la salud de la piel y el cabello. Rico en antioxidantes.','Aguaje.png','aguaje-x-60-tab-115',0,true),
('116','LAB. FITOSANA','AJO X 60 TAB','TABLETAS',6.00,'Reduce el colesterol y la presión arterial. Antibiótico natural.','Ajo.png','ajo-x-60-tab-116',0,true),
('117','LAB. FITOSANA','AJO PEREJIL X 60 TAB','TABLETAS',6.00,'Ayuda a controlar la presión arterial y elimina líquidos.','ajoperejil.jpg','ajo-perejil-x-60-tab-117',0,true),
('118','LAB. FITOSANA','ALOE VERA X 60 TAB','TABLETAS',6.00,'Mejora la digestión, la piel y el sistema inmunológico.','aloevera.jpg','aloe-vera-x-60-tab-118',0,true),
('119','LAB. FITOSANA','VITAMINA B5-ACIDO PANTOTENICO X 60 TAB','TABLETAS',6.00,'Reduce el estrés y mejora la salud de la piel y el cabello.',null,'vitamina-b5-acido-pantotenico-x-60-tab-119',0,true),
('120','LAB. FITOSANA','VITAMINAS HIERRO X 60 TAB','TABLETAS',6.00,'Combate la fatiga y la anemia. Aumenta la energía.','Vitamina C.png','vitaminas-hierro-x-60-tab-120',0,true),
('121','LAB. FITOSANA','VITAMINAS Y MINERALES X 60 TAB','TABLETAS',6.00,'Completo multivitamínico para la salud diaria.','Vitamina y Minerales.png','vitaminas-y-minerales-x-60-tab-121',0,true),
('122','LAB. FITOSANA','CALÉNDULA X 60 TAB','TABLETAS',6.00,'Antiinflamatorio natural. Mejora la salud de la piel y la digestión.','calendula.jpg','calendula-x-60-tab-122',0,true)
on conflict (id) do nothing;
