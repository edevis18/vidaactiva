/* VidaActiva · inventario y pedidos conectados a Supabase */
(function () {
  'use strict';
  const cfg = window.VIDAACTIVA_SUPABASE;
  if (!cfg || !window.supabase?.createClient) {
    console.error('VidaActiva: falta la configuración o el SDK de Supabase.');
    return;
  }
  const client = window.supabase.createClient(cfg.url, cfg.publishableKey);
  window.vidaActivaSupabase = client;

  // El catálogo conserva el formato original y recibe stock/precio desde la BD.
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
        presentation_lab: p.presentation_lab, price: p.base_price ?? 0,
        price_pending: p.base_price === null || Number(p.base_price) <= 0,
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
  function canBuy(p, qty) {
    if (!p) { toast('Producto no disponible.'); return false; }
    if (p.price_pending) { toast('El precio de este producto está pendiente de revisión.'); return false; }
    if (Number(p.stock) <= 0) { toast('Este producto está agotado.'); return false; }
    if (!Number.isInteger(qty) || qty < 1 || qty > Number(p.stock)) {
      toast('La cantidad supera las existencias disponibles.'); return false;
    }
    return true;
  }

  const originalAdd = window.addToCart;
  if (originalAdd) window.addToCart = function (id) {
    const p = findProduct(id), qty = Number(document.getElementById('qty-' + id)?.value || 1);
    if (!canBuy(p, qty)) return;
    return originalAdd(id);
  };
  const originalAddDetail = window.addToCartFromDetail;
  if (originalAddDetail) window.addToCartFromDetail = function (id) {
    const p = findProduct(id), qty = Number(document.getElementById('detail-qty-' + id)?.value || 1);
    if (!canBuy(p, qty)) return;
    return originalAddDetail(id);
  };

  ['incrementQuantity', 'incrementDetailQuantity'].forEach(name => {
    const original = window[name];
    if (!original) return;
    window[name] = function (id) {
      const p = findProduct(id);
      const input = document.getElementById((name === 'incrementQuantity' ? 'qty-' : 'detail-qty-') + id);
      if (!p || !input || p.price_pending || Number(p.stock) <= 0) return;
      if (Number(input.value) < Number(p.stock)) original(id);
    };
  });

  function shareProduct(p) {
    const url = 'https://vidaactiva.click/producto/' + encodeURIComponent(p.slug || p.id) + '/';
    const title = p.product_name + ' | VidaActiva';
    if (navigator.share) {
      navigator.share({ title, text: p.description || p.product_name, url }).catch(() => {});
    } else if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(url).then(() => toast('Enlace del producto copiado.', 'success'));
    } else {
      window.open('https://wa.me/?text=' + encodeURIComponent(title + ' ' + url), '_blank', 'noopener');
    }
  }

  const originalRender = window.renderGrid;
  if (originalRender) window.renderGrid = function () {
    originalRender();
    const store = window.store;
    if (!store) return;
    const start = ((store.page || 1) - 1) * 12;
    document.querySelectorAll('#products-container > div').forEach((card, index) => {
      const product = store.current[start + index];
      if (!product) return;
      const add = card.querySelector('button[onclick*="addToCart("]');
      const qty = card.querySelector('.quantity-selector');
      const badge = card.querySelector('.absolute.top-3.right-3');
      const price = card.querySelector('.product-price');
      const before = card.querySelector('.line-through');
      if (product.price_pending) {
        if (price) { price.textContent = 'Precio por confirmar'; price.classList.remove('text-lg'); price.classList.add('text-sm'); }
        if (before) before.classList.add('hidden');
      }
      if (badge && Number(product.stock) <= 0) {
        badge.textContent = 'Agotado';
        badge.classList.remove('bg-[#d6ca11]', 'text-dark');
        badge.classList.add('bg-red-600', 'text-white');
      }
      if (!card.querySelector('[data-stock-label]')) {
        const line = document.createElement('p');
        line.dataset.stockLabel = '1';
        line.className = 'text-xs font-semibold mb-2 ' + (product.stock > 0 ? 'text-gray-500' : 'text-red-600');
        line.textContent = product.stock > 0 ? 'Disponibles: ' + product.stock : 'Sin existencias';
        if (qty?.parentElement) qty.parentElement.insertBefore(line, qty);
      }
      if (Number(product.stock) <= 0 || product.price_pending) {
        if (qty) { qty.style.opacity = '.35'; qty.style.pointerEvents = 'none'; }
        if (add) {
          add.disabled = true;
          add.textContent = product.price_pending ? 'Precio por confirmar' : 'Agotado';
          add.classList.add('opacity-60', 'cursor-not-allowed');
        }
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
      const price = content.querySelector('.text-primary.font-black');
      if (p.price_pending && price) price.textContent = 'Precio por confirmar';
      const add = content.querySelector('button[onclick*="addToCartFromDetail"]');
      const qty = content.querySelector('.quantity-selector');
      if (Number(p.stock) <= 0 || p.price_pending) {
        if (add) { add.disabled = true; add.textContent = p.price_pending ? 'Precio por confirmar' : 'Agotado'; add.classList.add('opacity-60','cursor-not-allowed'); }
        if (qty) { qty.style.opacity = '.35'; qty.style.pointerEvents = 'none'; }
      }
      if (!content.querySelector('[data-share-product]')) {
        const share = document.createElement('button');
        share.type = 'button'; share.dataset.shareProduct = '1';
        share.className = 'w-full mt-2 bg-gray-100 text-gray-700 py-2 rounded-xl text-sm font-bold';
        share.textContent = 'Compartir producto';
        share.addEventListener('click', () => shareProduct(p));
        content.appendChild(share);
      }
    }
    return result;
  };

  // Registra el pedido en Supabase antes de abrir WhatsApp. No reserva ni descuenta stock.
  window.checkoutWhatsApp = async function () {
    const store = window.store;
    if (!store || !store.cart.length) return toast('Agrega productos al carrito primero.');
    const get = id => document.getElementById(id)?.value?.trim() || '';
    const name = get('form-nombre') + ' ' + get('form-apellido');
    const phone = get('form-tel'), email = get('form-email');
    const city = get('form-ciudad'), state = get('form-estado'), address = get('form-direccion');
    if (!name.trim() || !phone || !email || !city || !state || !address) return toast('Completa todos los datos del pedido.');
    const items = store.cart.map(item => ({ product_id: String(item.id), quantity: Number(item.quantity) }));
    if (items.some(item => !Number.isInteger(item.quantity) || item.quantity < 1)) return toast('Hay cantidades inválidas en el carrito.');
    const popup = window.open('about:blank', '_blank');
    const { data: order, error } = await client.rpc('create_store_order', {
      p_customer_name: name.trim(), p_customer_phone: phone, p_customer_email: email,
      p_customer_address: address + ', ' + city + ', ' + state, p_notes: '',
      p_items: items, p_idempotency_key: crypto.randomUUID()
    });
    if (error || !order) {
      if (popup) popup.close();
      return toast(error?.message || 'No se pudo registrar el pedido. Revisa las existencias.');
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

  // Compatibilidad con enlaces ?producto=ID que ya se compartieron anteriormente.
  const originalSetup = window.setupUI;
  if (originalSetup) window.setupUI = function () {
    const result = originalSetup();
    const id = new URLSearchParams(location.search).get('producto');
    if (id) setTimeout(() => window.openProductDetail(id), 300);
    return result;
  };
})();