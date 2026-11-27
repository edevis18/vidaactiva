import fs from 'node:fs';
import path from 'node:path';

const ROOT = process.cwd();
const SITE = 'https://vidaactiva.click';
const raw = fs.readFileSync(path.join(ROOT, 'products.json'), 'utf8').trim();
const products = JSON.parse('[' + raw.replace(/},\\s*{/g, '},{') + ']');
const outRoot = path.join(ROOT, 'producto');
const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, ch => ({
  '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
}[ch]));
const safeSlug = value => String(value ?? '').normalize('NFD')
  .replace(/[\\u0300-\\u036f]/g, '').toLowerCase()
  .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

const urls = [];
for (const p of products) {
  const slug = safeSlug(p.product_name) + '-' + safeSlug(p.id);
  const dir = path.join(outRoot, slug);
  fs.mkdirSync(dir, { recursive: true });
  const canonical = SITE + '/producto/' + slug + '/';
  const image = p.img_product
    ? SITE + '/img/productos/' + encodeURIComponent(p.img_product)
    : SITE + '/img/envase.jpg';
  const name = escapeHtml(p.product_name);
  const presentation = escapeHtml(p.presentation_lab || '');
  const descriptionText = (p.description || '').trim();
  const description = escapeHtml(descriptionText || ('Información, presentación y disponibilidad de ' + p.product_name + ' en VidaActiva.'));
  const jsonLd = {
    '@context':'https://schema.org',
    '@type':'Product',
    name:p.product_name,
    description:descriptionText || ('Información, presentación y disponibilidad de ' + p.product_name + ' en VidaActiva.'),
    image:[image],
    sku:String(p.id),
    brand:{'@type':'Brand',name:'VidaActiva'},
    url:canonical
  };
  const page = `<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${name} | VidaActiva</title>
<meta name="description" content="${description}">
<link rel="canonical" href="${canonical}">
<meta property="og:type" content="product">
<meta property="og:site_name" content="VidaActiva">
<meta property="og:title" content="${name} | VidaActiva">
<meta property="og:description" content="${description}">
<meta property="og:url" content="${canonical}">
<meta property="og:image" content="${image}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${name} | VidaActiva">
<meta name="twitter:description" content="${description}">
<meta name="twitter:image" content="${image}">
<script type="application/ld+json">${JSON.stringify(jsonLd).replace(/</g,'\\u003c')}</script>
<style>
*{box-sizing:border-box}body{margin:0;background:#f7f8fa;color:#17212b;font-family:Arial,Helvetica,sans-serif}
main{max-width:900px;margin:36px auto;padding:24px;background:#fff;border-radius:20px;box-shadow:0 8px 32px #10203012}
a{color:#176b55}.brand{font-weight:800;letter-spacing:.08em;text-transform:uppercase;color:#176b55}
.product{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:30px;align-items:center;margin-top:24px}
img{width:100%;height:auto;max-height:420px;object-fit:contain}.muted{color:#64748b;line-height:1.6}
.actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:22px}
button,.button{border:0;border-radius:10px;padding:13px 17px;background:#176b55;color:white;text-decoration:none;font-weight:700;cursor:pointer}
button.alt,.button.alt{background:#edf2f0;color:#174b3c}
@media(max-width:650px){main{margin:12px;padding:18px}.product{grid-template-columns:1fr;gap:16px}img{max-height:300px}}
</style>
</head>
<body>
<main>
<a class="brand" href="/">VidaActiva</a>
<div class="product">
<div><img src="${image}" alt="${name}" loading="eager"></div>
<section>
<p class="muted">Catálogo VidaActiva</p>
<h1>${name}</h1>
<p>${presentation}</p>
<p class="muted">${description}</p>
<p class="muted">Consulta en la tienda el precio actualizado y la disponibilidad de este producto.</p>
<div class="actions">
<a class="button" href="/?producto=${encodeURIComponent(String(p.id))}">Ver producto en la tienda</a>
<button class="alt" id="share">Compartir producto</button>
<button class="alt" id="copy">Copiar enlace</button>
</div>
<p class="muted"><a href="/">Volver a VidaActiva</a></p>
</section>
</div>
</main>
<script>
const url=location.href;
document.getElementById('share').addEventListener('click',async()=>{
 if(navigator.share){try{await navigator.share({title:document.title,url})}catch(e){}}
 else{window.open('https://wa.me/?text='+encodeURIComponent(document.title+' '+url),'_blank','noopener')}
});
document.getElementById('copy').addEventListener('click',async()=>{
 try{await navigator.clipboard.writeText(url);document.getElementById('copy').textContent='Enlace copiado'}
 catch(e){window.prompt('Copia este enlace:',url)}
});
</script>
</body>
</html>`;
  fs.writeFileSync(path.join(dir, 'index.html'), page, 'utf8');
  urls.push(canonical);
}

const staticPaths = ['/', '/nosotros.html', '/politicas.html', '/terminos.html', '/descargar-lista.html'];
const allUrls = [...new Set([...staticPaths.map(p => SITE + p), ...urls])];
const lastmod = new Date().toISOString().slice(0,10);
const sitemap = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
  allUrls.map(url => `  <url><loc>${url}</loc><lastmod>${lastmod}</lastmod></url>`).join('\n') +
  '\n</urlset>\n';
fs.writeFileSync(path.join(ROOT, 'sitemap.xml'), sitemap, 'utf8');
console.log(`SEO: generadas ${products.length} páginas de producto y ${allUrls.length} URLs en sitemap.xml`);
