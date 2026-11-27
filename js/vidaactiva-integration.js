/* VidaActiva - integración segura de inventario y pedidos */
(function () {
  'use strict';
  const client = window.supabase.createClient(
    window.VIDAACTIVA_SUPABASE.url,
    window.VIDAACTIVA_SUPABASE.publishableKey
  );
  window.vidaActivaSupabase = client;

  // Mantiene el formato de datos que ya consume el catálogo original.
  const nativeFetch = window.fetch.bind(window);
  window.fetch = async function (resource, options) {
    const url = typeof resource === 'string' ? resource : (resource && resource.url) || '';
    if (url.endsWith('products.json')) {
      const { data, error } = await client.from('products')
        .select('id,category,product_name,presentation_lab,base_price,description,image_file,slug,stock')
        .eq('active', true).order('product_name');
      if (error) throw error;
      const rows = (data || []).map(p => ({
        id: p.id, category: p.category, product_name: p.product_name,
        presentation_lab: p.presentation_lab, price: p.base_price,
        description: p.description, img_product: p.image_file,
        stock: Number(p.stock || 0), slug: p.slug
      }));
      return new Response(rows.map(row => JSON.stringify(row)).join(',\n'), {
        status: 200, headers: { 'Content-Type': 'application/json; charset=utf-8' }
      });
    }
    return nativeFetch(resource, options);
  };

  function toast(message, type) {
    if (typeof window.showToast === 'function') window.showToast(message, type || 'warning', 4500);
    else alert(message);
  }
  function findProduct(id) {
    return window.store && window.store.all.find(p => String(p.id) === String(id));
  }

  const originalAdd = window.addToCart;
  if (originalAdd) window.addToCart = function (id) {
    const p = findProduct(id), qty = Number(document.getElementById('qty-' + id)?.value || 1);
    if (!p || p.stock <= 0) return toast('Este producto está agotado.');
    if (qty < 1 || qty > p.stock) return toast('La cantidad supera las existencias disponibles.');
    return originalAdd(id);
  };

  const originalAddDetail = window.addToCartFromDetail;
  if (originalAddDetail) window.addToCartFromDetail = function (id) {
    const p = findProduct(id), qty = Number(document.getElementById('detail-qty-' + id)?.value || 1);
    if (!p || p.stock <= 0) return toast('Este producto está agotado.');
    if (qty < 1 || qty > p.stock) return toast('La cantidad supera las existencias disponibles.');
    return originalAddDetail(id);
  };

  ['incrementQuantity', 'incrementDetailQuantity'].forEach(name => {
    const original = window[name];
    if (!original) return;
    window[name] = function (id) {
      const p = findProduct(id);
      const input = document.getElementById((name === 'incrementQuantity' ? 'qty-' : 'detail-qty-') + id);
      if (!p || !input || p.stock <= 0) return;
      if (Number(input.value) < p.stock) original(id);
    };
  });

  // Etiqueta y controles de stock en las tarjetas sin rediseñar el catálogo.
  const originalRender = window.renderGrid;
  if (originalRender) window.renderGrid = function () {
    originalRender();
    const store = window.store;
    const start = ((store.page || 1) - 1) * 12;
    document.querySelectorAll('#products-container > div').forEach((card, index) => {
      const product = store.current[start + index];
      if (!product) return;
      const add = card.querySelector('button[onclick*="addToCart("]');
      const qty = card.querySelector('.quantity-selector');
      const badge = card.querySelector('.absolute.top-3.right-3');
      if (badge && Number(product.stock) <= 0) {
        badge.textContent = 'Agotado';
        badge.classList.remove('bg-[#d6ca11]', 'text-dark');
        badge.classList.add('bg-red-600', 'text-white');
      }
      const line = document.createElement('p');
      line.className = 'text-xs font-semibold mb-2 ' + (product.stock > 0 ? 'text-gray-500' : 'text-red-600');
      line.textContent = product.stock > 0 ? 'Disponibles: ' + product.stock : 'Sin existencias';
      if (qty && !qty.parentElement.querySelector('[data-stock-label]')) {
        line.dataset.stockLabel = '1';
        qty.parentElement.insertBefore(line, qty);
      }
      if (Number(product.stock) <= 0) {
        if (qty) { qty.style.opacity = '.35'; qty.style.pointerEvents = 'none'; }
        if (add) { add.disabled = true; add.textContent = 'Agotado'; add.classList.add('opacity-60','cursor-not-allowed'); }
      } else if (add) {
        add.disabled = false;
      }
    });
  };

  const originalDetail = window.openProductDetail;
  if (originalDetail) window.openProductDetail = function (id) {
    const result = originalDetail(id), p = findProduct(id);
    if (!p) return result;
    const content = document.getElementById('product-detail-content');
    if (content) {
      const stock = document.createElement('p');
      stock.className = 'text-sm font-bold mb-2 ' + (p.stock > 0 ? 'text-gray-500' : 'text-red-600');
      stock.textContent = p.stock > 0 ? 'Disponibles: ' + p.stock : 'Agotado';
      const title = content.querySelector('h3');
      if (title) title.after(stock);
      const add = content.querySelector('button[onclick*="addToCartFromDetail"]');
      const qty = content.querySelector('.quantity-selector');
      if (p.stock <= 0) {
        if (add) { add.disabled = true; add.textContent = 'Agotado'; add.classList.add('opacity-60','cursor-not-allowed'); }
        if (qty) { qty.style.opacity = '.35'; qty.style.pointerEvents = 'none'; }
      }
    }
    return result;
  };

  // Los pedidos se guardan en la base antes de abrir WhatsApp.
  window.checkoutWhatsApp = async function () {
    const store = window.store;
    if (!store || !store.cart.length) return toast('Agrega productos al carrito primero.');
    const get = id => document.getElementById(id)?.value?.trim() || '';
    const name = get('form-nombre') + ' ' + get('form-apellido');
    const phone = get('form-tel'), email = get('form-email');
    const city = get('form-ciudad'), state = get('form-estado'), address = get('form-direccion');
    if (!name.trim() || !phone || !email || !city || !state || !address) return toast('Completa todos los datos del pedido.');
    const items = store.cart.map(item => ({ product_id: String(item.id), quantity: Number(item.quantity) }));
    const popup = window.open('about:blank', '_blank');
    const { data: order, error } = await client.rpc('create_store_order', {
      p_customer_name: name.trim(), p_customer_phone: phone, p_customer_email: email,
      p_customer_address: address + ', ' + city + ', ' + state, p_notes: '',
      p_items: items, p_idempotency_key: crypto.randomUUID()
    });
    if (error) {
      if (popup) popup.close();
      return toast(error.message || 'No se pudo registrar el pedido. Revisa las existencias.');
    }
    let message = 'PEDIDO VIDAACTIVA.CLICK\nPedido: #' + order.order_number +
      '\nCliente: ' + name + '\nTeléfono: ' + phone + '\nDirección: ' + address + ', ' + city + ', ' + state + '\n\nProductos:\n';
    store.cart.forEach(item => { message += item.product_name + ' x' + item.quantity + '\n'; });
    message += '\nTOTAL: $' + Number(order.total).toFixed(2) +
      '\nEstado: pendiente de verificación del pago. No se ha descontado inventario.';
    const wa = 'https://wa.me/5804143688401?text=' + encodeURIComponent(message);
    if (popup) popup.location.href = wa; else window.location.href = wa;
    store.cart = []; store.discount = 0; store.couponApplied = false; store.currentCoupon = null;
    localStorage.setItem('natur_cart', JSON.stringify(store.cart));
    if (typeof window.updateCartUI === 'function') window.updateCartUI();
    if (typeof window.closeCart === 'function') window.closeCart();
    toast('Pedido #' + order.order_number + ' registrado. El inventario se descontará al verificar el pago.', 'success');
  };

  // Deep link SEO: /?producto=<id> abre el detalle tras cargar el catálogo.
  const originalSetup = window.setupUI;
  if (originalSetup) window.setupUI = function () {
    const result = originalSetup();
    const id = new URLSearchParams(location.search).get('producto');
    if (id) setTimeout(() => window.openProductDetail(id), 300);
    return result;
  };
})();