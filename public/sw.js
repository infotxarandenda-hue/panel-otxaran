// Panel Otxaran como aplicación instalable.
// No guarda datos de la tienda: todo va siempre a Shopify en directo. Solo muestra un aviso si no hay conexión.
const SIN_CONEXION = `<!doctype html><html lang="es"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Panel · Otxaran</title>
<body style="margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:Jost,Arial,sans-serif;background:#fff;color:#111;text-align:center;padding:24px">
<div><p style="font-weight:600;letter-spacing:0.12em;font-size:20px;margin:0 0 14px">OTXARAN</p>
<p style="margin:0 0 22px;color:#555">No hay conexión a internet. El panel necesita conexión para hablar con Shopify.</p>
<button onclick="location.reload()" style="font:inherit;letter-spacing:0.1em;text-transform:uppercase;font-size:12px;background:#111;color:#fff;border:0;padding:14px 26px;cursor:pointer">Reintentar</button></div>`;

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

self.addEventListener("fetch", e => {
  if (e.request.mode !== "navigate") return;   // fotos, API, etc.: el navegador las pide normal
  e.respondWith(fetch(e.request).catch(() =>
    new Response(SIN_CONEXION, { headers: { "Content-Type": "text/html; charset=utf-8" } })));
});
