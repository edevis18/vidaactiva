(function(){
'use strict';
const cfg=window.VIDAACTIVA_SUPABASE;
if(!cfg||!window.supabase){document.getElementById('login-message').textContent='No se pudo cargar la conexión con Supabase.';return;}
const db=window.supabase.createClient(cfg.url,cfg.publishableKey);
const $=id=>document.getElementById(id);
const money=n=>'$'+Number(n||0).toFixed(2);
const statusText={pending_payment:'Pendiente de pago',payment_under_review:'Pago en revisión',paid_confirmed:'Pagado y confirmado',payment_rejected:'Pago rechazado',cancelled:'Cancelado',stock_issue:'Problema de inventario'};
function message(id,text,error){const el=$(id);el.textContent=text;el.style.background=error?'#fee2e2':'#f1f5f9';el.style.color=error?'#991b1b':'#334155';}
async function checkAdmin(session){
 if(!session){$('dashboard').classList.add('hidden');$('login-panel').classList.remove('hidden');return false;}
 const {data,error}=await db.from('admin_users').select('user_id,role').eq('user_id',session.user.id).maybeSingle();
 if(error||!data){await db.auth.signOut();message('login-message','Esta cuenta no tiene permisos de administración.',true);return false;}
 $('admin-email').textContent=session.user.email||'Administrador';
 $('login-panel').classList.add('hidden');$('dashboard').classList.remove('hidden');
 await Promise.all([loadProducts(),loadOrders()]);
 return true;
}
async function loadProducts(){
 const {data,error}=await db.from('products').select('id,product_name,base_price,stock,active').order('product_name');
 if(error){message('dashboard-message','No se pudo cargar el inventario: '+error.message,true);return;}
 window.adminProducts=data||[];renderProducts(window.adminProducts);
}
function renderProducts(rows){
 $('products-body').innerHTML=rows.map(p=>'<tr><td><strong>'+esc(p.product_name)+'</strong><div class="muted">ID '+esc(p.id)+(p.active?'':' · Oculto')+'</div></td><td>'+(p.base_price>0?money(p.base_price*2):'<span class="pill">Precio por revisar</span>')+'</td><td><span class="pill">'+Number(p.stock||0)+'</span></td><td><input class="stock-input" type="number" min="0" step="1" value="'+Number(p.stock||0)+'" id="stock-'+esc(p.id)+'"></td><td><button data-save-stock="'+esc(p.id)+'">Guardar</button></td></tr>').join('');
 $('products-body').querySelectorAll('[data-save-stock]').forEach(btn=>btn.addEventListener('click',()=>saveStock(btn.dataset.saveStock)));
}
async function saveStock(id){
 const input=$('stock-'+id), value=Number(input.value);
 if(!Number.isInteger(value)||value<0){message('dashboard-message','El stock debe ser un entero igual o mayor que cero.',true);return;}
 const {error}=await db.rpc('admin_adjust_product_stock',{p_product_id:String(id),p_new_stock:value,p_note:'Actualización desde panel administrativo'});
 if(error){message('dashboard-message',error.message,true);return;}
 message('dashboard-message','Inventario actualizado correctamente.',false);await loadProducts();
}
async function loadOrders(){
 const {data:orders,error}=await db.from('orders').select('id,order_number,status,customer_name,customer_phone,customer_email,customer_address,total,created_at').order('created_at',{ascending:false}).limit(100);
 if(error){message('dashboard-message','No se pudieron cargar los pedidos: '+error.message,true);return;}
 const ids=(orders||[]).map(o=>o.id);
 let items=[];
 if(ids.length){const res=await db.from('order_items').select('order_id,product_name,quantity').in('order_id',ids);if(!res.error)items=res.data||[];}
 $('orders-body').innerHTML=(orders||[]).map(o=>{
   const detail=items.filter(i=>i.order_id===o.id).map(i=>esc(i.product_name)+' × '+i.quantity).join('<br>');
   const actions=o.status==='pending_payment'||o.status==='payment_under_review'
     ?'<div class="actions"><button data-confirm="'+o.id+'">Confirmar pago</button><button class="danger" data-reject="'+o.id+'">Rechazar</button><button class="secondary" data-review="'+o.id+'">En revisión</button></div>'
     :'<span class="muted">Sin acciones</span>';
   return '<tr><td><strong>#'+o.order_number+'</strong><div class="muted">'+new Date(o.created_at).toLocaleString('es-VE')+'</div></td><td>'+esc(o.customer_name)+'<div class="muted">'+esc(o.customer_phone)+' · '+esc(o.customer_email||'')+'</div><div class="muted">'+esc(o.customer_address||'')+'</div></td><td><div class="order-items">'+detail+'</div></td><td><strong>'+money(o.total)+'</strong></td><td><span class="pill">'+(statusText[o.status]||esc(o.status))+'</span></td><td>'+actions+'</td></tr>';
 }).join('')||'<tr><td colspan="6">Todavía no hay pedidos.</td></tr>';
 $('orders-body').querySelectorAll('[data-confirm]').forEach(b=>b.addEventListener('click',()=>confirmOrder(b.dataset.confirm)));
 $('orders-body').querySelectorAll('[data-reject]').forEach(b=>b.addEventListener('click',()=>rejectOrder(b.dataset.reject)));
 $('orders-body').querySelectorAll('[data-review]').forEach(b=>b.addEventListener('click',()=>markReview(b.dataset.review)));
}
async function confirmOrder(id){
 if(!confirm('¿Confirmaste el pago de este pedido? Solo entonces se descontará el inventario.'))return;
 const {error}=await db.rpc('confirm_store_order_payment',{p_order_id:id});
 if(error){message('dashboard-message',error.message,true);return;}
 message('dashboard-message','Pago confirmado e inventario actualizado.',false);await Promise.all([loadOrders(),loadProducts()]);
}
async function rejectOrder(id){
 if(!confirm('¿Rechazar el pago de este pedido? No se descontará inventario.'))return;
 const {error}=await db.rpc('reject_store_order_payment',{p_order_id:id});
 if(error){message('dashboard-message',error.message,true);return;}
 message('dashboard-message','Pedido marcado como pago rechazado.',false);await loadOrders();
}
async function markReview(id){
 const {error}=await db.from('orders').update({status:'payment_under_review'}).eq('id',id);
 if(error){message('dashboard-message',error.message,true);return;}
 message('dashboard-message','Pedido marcado en revisión.',false);await loadOrders();
}
function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
$('login-form').addEventListener('submit',async e=>{
 e.preventDefault();message('login-message','Validando acceso…',false);
 const {data,error}=await db.auth.signInWithPassword({email:$('email').value.trim(),password:$('password').value});
 if(error){message('login-message',error.message,true);return;}
 await checkAdmin(data.session);
});
$('logout').addEventListener('click',async()=>{await db.auth.signOut();location.reload();});
$('refresh-orders').addEventListener('click',loadOrders);
$('product-search').addEventListener('input',e=>{const q=e.target.value.toLowerCase();renderProducts((window.adminProducts||[]).filter(p=>p.product_name.toLowerCase().includes(q)||String(p.id).includes(q)));});
db.auth.getSession().then(({data})=>checkAdmin(data.session));
})();