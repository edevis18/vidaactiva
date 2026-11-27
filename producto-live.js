(function () {
  const id = document.body.dataset.productId;
  if (!id || !window.supabase) return;
  const client = window.supabase.createClient(
    "https://kyuexpenylndneekcsaj.supabase.co",
    "sb_publishable_aGi8VYxdOSje8wBNjHf2UQ_pC9m1DO9"
  );
  client.from("products")
    .select("stock,base_price,active")
    .eq("id", id)
    .maybeSingle()
    .then(({ data, error }) => {
      if (error || !data || !data.active) {
        const status = document.getElementById("stock-status");
        if (status) status.textContent = "Producto no disponible";
        return;
      }
      const price = (Number(data.base_price) * 2).toFixed(2);
      const status = document.getElementById("stock-status");
      if (status) {
        status.textContent = data.stock > 0
          ? "Disponible: " + data.stock + " unidades"
          : "Agotado temporalmente";
        status.style.color = data.stock > 0 ? "#137547" : "#b42318";
      }
      const priceEl = document.querySelector(".price");
      if (priceEl) priceEl.textContent = "$" + price;
      const schema = document.getElementById("product-jsonld");
      if (schema) {
        const json = JSON.parse(schema.textContent);
        json.offers.price = price;
        json.offers.availability = data.stock > 0
          ? "https://schema.org/InStock"
          : "https://schema.org/OutOfStock";
        schema.textContent = JSON.stringify(json);
      }
    });
})();