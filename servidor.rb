#!/usr/bin/env ruby
# Servidor del panel de Otxaran.
# Sirve el panel (public/index.html) y es lo único que habla con Shopify: la clave de la app
# se queda aquí y el navegador solo ve las rutas /api/... de abajo.
#
# Uso:  ruby servidor.rb        (lee la configuración de .env; ver .env.ejemplo)
# Sin credenciales arranca en «modo demo»: usa datos-demo.json y no guarda nada en Shopify.

require 'webrick'
require 'net/http'
require 'json'
require 'uri'
require 'cgi'
require 'securerandom'

Encoding.default_external = Encoding::UTF_8 # tildes y eñes aunque el Mac no tenga el idioma configurado
DIR = File.expand_path(__dir__)

# ---------- configuración (.env) ----------
env_file = File.join(DIR, '.env')
if File.exist?(env_file)
  File.readlines(env_file, encoding: 'utf-8').each do |linea|
    linea = linea.strip
    next if linea.empty? || linea.start_with?('#') || !linea.include?('=')
    k, v = linea.split('=', 2)
    ENV[k.strip] ||= v.strip.sub(/\A["']/, '').sub(/["']\z/, '')
  end
end

TIENDA        = ENV['SHOPIFY_TIENDA'].to_s.sub(%r{\Ahttps?://}, '').sub(%r{/.*\z}, '')
CLIENT_ID     = ENV['SHOPIFY_CLIENT_ID'].to_s
CLIENT_SECRET = ENV['SHOPIFY_CLIENT_SECRET'].to_s
API_VERSION   = ENV['SHOPIFY_API_VERSION'] || '2026-07'
# En la nube (Render y similares) el alojamiento da el puerto en PORT y el panel queda abierto a internet
EN_LA_NUBE    = !ENV['PORT'].to_s.empty?
PUERTO        = (ENV['PORT'] || ENV['PUERTO'] || 4300).to_i
CLAVE         = ENV['CLAVE_PANEL'].to_s
ABIERTO       = EN_LA_NUBE || ENV['ABIERTO'] == '1'
MODO          = [TIENDA, CLIENT_ID, CLIENT_SECRET].any?(&:empty?) ? 'demo' : 'shopify'

TIPOS = ['Camisas y tops', 'Chaquetas y abrigos', 'Punto', 'Pantalones', 'Faldas', 'Accesorios'].freeze

# ---------- textos: descripción en texto plano <-> HTML de Shopify ----------
def texto_a_html(texto)
  texto.to_s.strip.split(/\n\s*\n/).map do |bloque|
    lineas = bloque.split("\n").map(&:strip).reject(&:empty?)
    vinetas, resto = lineas.partition { |l| l =~ /\A[•\-*]\s*/ }
    html = resto.empty? ? '' : "<p>#{resto.map { |l| CGI.escapeHTML(l) }.join('<br>')}</p>"
    html + (vinetas.empty? ? '' : "<ul>#{vinetas.map { |l| "<li>#{CGI.escapeHTML(l.sub(/\A[•\-*]\s*/, ''))}</li>" }.join}</ul>")
  end.join
end

def html_a_texto(html)
  t = html.to_s.gsub(/<li[^>]*>/i, '• ').gsub(%r{</li>}i, "\n").gsub(%r{</p>|</ul>}i, "\n\n")
          .gsub(%r{<br\s*/?>}i, "\n").gsub(/<[^>]+>/, '')
  CGI.unescapeHTML(t).gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n").strip
end

class ErrorPanel < StandardError
  attr_reader :estado
  def initialize(mensaje, estado = 400)
    super(mensaje)
    @estado = estado
  end
end

# ---------- conexión con Shopify ----------
module Shopify
  @token = nil
  @caduca = Time.at(0)
  @mutex = Mutex.new
  @contexto = nil

  def self.token
    @mutex.synchronize do
      if @token.nil? || Time.now >= @caduca
        res = Net::HTTP.post_form(URI("https://#{TIENDA}/admin/oauth/access_token"),
                                  'client_id' => CLIENT_ID, 'client_secret' => CLIENT_SECRET,
                                  'grant_type' => 'client_credentials')
        unless res.code == '200'
          motivo = if res.body.to_s.include?('app_not_installed')
                     'la app está creada pero no instalada en la tienda. En dev.shopify.com → tu app → «Instalar app» → elige la tienda.'
                   elsif res.body.to_s =~ /invalid_client|invalid client/i
                     'el Client ID o el Client secret no son correctos. Vuelve a copiarlos en .env.'
                   else
                     'revisa el Client ID, el Client secret y que la app esté instalada en la tienda.'
                   end
          raise ErrorPanel.new("Shopify no ha dado acceso (#{res.code}): #{motivo}", 502)
        end
        j = JSON.parse(res.body)
        @token = j['access_token']
        @caduca = Time.now + j['expires_in'].to_i - 300 # se renueva 5 min antes de caducar
      end
      @token
    end
  end

  def self.gql(query, vars = {})
    uri = URI("https://#{TIENDA}/admin/api/#{API_VERSION}/graphql.json")
    req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json', 'X-Shopify-Access-Token' => token)
    req.body = JSON.generate(query: query, variables: vars)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) { |h| h.request(req) }
    @token = nil if res.code == '401'
    j = JSON.parse(res.body) rescue raise(ErrorPanel.new("Respuesta rara de Shopify (#{res.code})", 502))
    if j['errors']
      msg = j['errors'].is_a?(Array) ? j['errors'].map { |e| e['message'] }.join('; ') : j['errors'].to_s
      raise ErrorPanel.new("Shopify: #{msg}", 502)
    end
    j['data']
  end

  # Lanza un error legible si la mutación devuelve userErrors
  def self.ok!(resultado)
    errores = resultado && resultado['userErrors']
    raise ErrorPanel.new(errores.map { |e| e['message'] }.join('; ')) if errores && !errores.empty?
    resultado
  end

  def self.contexto
    @contexto ||= begin
      d = gql(<<~Q)
        query init { shop { name myshopifyDomain currencyCode primaryDomain { url } }
          locations(first: 5, query: "active:true") { nodes { id name } }
          publications(first: 10) { nodes { id name } } }
      Q
      loc = d['locations']['nodes'].first or raise ErrorPanel.new('La tienda no tiene ninguna ubicación activa', 500)
      pubs = d['publications']['nodes'].select { |p| p['name'] =~ /online|point of sale|punto de venta/i }.map { |p| p['id'] }
      { 'tienda' => d['shop']['name'], 'dominio' => d['shop']['primaryDomain']['url'],
        'admin' => "https://admin.shopify.com/store/#{d['shop']['myshopifyDomain'].sub('.myshopify.com', '')}",
        'ubicacion' => loc, 'publicaciones' => pubs }
    end
  end

  Q_PRODUCTOS = <<~Q
    query productos($after: String, $loc: ID!) {
      products(first: 50, after: $after, sortKey: CREATED_AT, reverse: true) {
        pageInfo { hasNextPage endCursor }
        nodes { id handle title status productType vendor tags descriptionHtml totalInventory onlineStoreUrl
          media(first: 20) { nodes { id ... on MediaImage { image { url(transform: {maxWidth: 900}) } } } }
          options { name values }
          variants(first: 100) { nodes { id title sku price selectedOptions { name value }
            inventoryItem { id inventoryLevel(locationId: $loc) { quantities(names: ["available"]) { name quantity } } } } } } } }
  Q

  def self.productos
    loc = contexto['ubicacion']['id']
    lista = []
    cursor = nil
    loop do
      d = gql(Q_PRODUCTOS, after: cursor, loc: loc)['products']
      lista.concat(d['nodes'])
      break unless d['pageInfo']['hasNextPage']
      cursor = d['pageInfo']['endCursor']
    end
    lista.map { |p| normalizar(p) }
  end

  def self.producto(id)
    productos.find { |p| p['id'] == id } or raise ErrorPanel.new('No encuentro esa prenda', 404)
  end

  def self.normalizar(p)
    {
      'id' => p['id'], 'handle' => p['handle'], 'titulo' => p['title'], 'estado' => p['status'],
      'tipo' => p['productType'], 'marca' => p['vendor'], 'etiquetas' => p['tags'],
      'descripcion' => html_a_texto(p['descriptionHtml']), 'url' => p['onlineStoreUrl'],
      'fotos' => p['media']['nodes'].select { |m| m['image'] }.map { |m| { 'id' => m['id'], 'url' => m['image']['url'] } },
      'opciones' => p['options'].map { |o| { 'nombre' => o['name'], 'valores' => o['values'] } },
      'variantes' => p['variants']['nodes'].map do |v|
        lvl = v['inventoryItem']['inventoryLevel']
        {
          'id' => v['id'], 'titulo' => v['title'], 'sku' => v['sku'], 'precio' => v['price'].to_f,
          'opciones' => v['selectedOptions'].map { |o| [o['name'], o['value']] }.to_h,
          'item' => v['inventoryItem']['id'],
          'stock' => lvl ? lvl['quantities'].first['quantity'] : 0
        }
      end
    }
  end

  M_STOCK = <<~Q
    mutation stock($input: InventorySetQuantitiesInput!, $clave: String!) { inventorySetQuantities(input: $input) @idempotent(key: $clave) {
      inventoryAdjustmentGroup { changes { name delta quantityAfterChange } } userErrors { field message code } } }
  Q

  # Shopify exige una clave única por cambio de stock (@idempotent) para no aplicarlo dos veces.
  # changeFromQuantity = lo que el panel creía que había: si entretanto hubo una venta, Shopify no pisa el dato
  def self.poner_stock(item, cantidad, anterior)
    r = gql(M_STOCK, input: {
      name: 'available', reason: 'correction', referenceDocumentUri: 'gid://otxaran-panel/Stock/manual',
      quantities: [{ inventoryItemId: item, locationId: contexto['ubicacion']['id'], quantity: cantidad, changeFromQuantity: anterior }]
    }, clave: SecureRandom.uuid)['inventorySetQuantities']
    errores = r['userErrors'] || []
    if errores.any? { |e| e['code'].to_s =~ /STALE/ }
      raise ErrorPanel.new('El stock de esta talla ha cambiado mientras tanto (quizá una venta). He recargado los datos: vuelve a mirarlo.', 409)
    end
    ok!(r)
    { 'stock' => cantidad }
  end

  def self.publicar(id)
    pubs = contexto['publicaciones']
    return if pubs.empty?
    ok!(gql('mutation publicar($id: ID!, $input: [PublicationInput!]!) { publishablePublish(id: $id, input: $input) { userErrors { field message } } }',
            id: id, input: pubs.map { |p| { publicationId: p } })['publishablePublish'])
  end

  def self.crear(datos)
    loc = contexto['ubicacion']['id']
    tallas = datos['tallas']
    input = {
      title: datos['titulo'], descriptionHtml: texto_a_html(datos['descripcion']), vendor: datos['marca'],
      productType: datos['tipo'], tags: datos['etiquetas'], status: datos['estado'],
      productOptions: [{ name: 'Talla', values: tallas.map { |t| { name: t } } }],
      variants: tallas.map do |t|
        { optionValues: [{ optionName: 'Talla', name: t }], price: format('%.2f', datos['precio']),
          sku: "#{datos['sku']}-#{t.upcase.delete(' ')}", inventoryItem: { tracked: true },
          inventoryQuantities: [{ locationId: loc, name: 'available', quantity: datos['stock'][t].to_i }] }
      end
    }
    r = ok!(gql('mutation crear($input: ProductSetInput!) { productSet(input: $input, synchronous: true) { product { id } userErrors { field message } } }',
                input: input)['productSet'])
    id = r['product']['id']
    publicar(id)
    preparar_para_web(id) if datos['estado'] == 'ACTIVE'
    id
  end

  def self.editar(id, datos)
    cambios = { id: id }
    cambios[:title] = datos['titulo'] if datos.key?('titulo')
    cambios[:productType] = datos['tipo'] if datos.key?('tipo')
    cambios[:vendor] = datos['marca'] if datos.key?('marca')
    cambios[:descriptionHtml] = texto_a_html(datos['descripcion']) if datos.key?('descripcion')
    cambios[:status] = datos['estado'] if datos.key?('estado')
    ok!(gql('mutation editar($product: ProductUpdateInput!) { productUpdate(product: $product) { product { id } userErrors { field message } } }',
            product: cambios)['productUpdate'])
    if datos.key?('precio')
      variantes = gql('query v($id: ID!) { product(id: $id) { variants(first: 100) { nodes { id } } } }', id: id)['product']['variants']['nodes']
      ok!(gql('mutation precio($productId: ID!, $variants: [ProductVariantsBulkInput!]!) { productVariantsBulkUpdate(productId: $productId, variants: $variants) { productVariants { id } userErrors { field message } } }',
              productId: id, variants: variantes.map { |v| { id: v['id'], price: format('%.2f', datos['precio']) } })['productVariantsBulkUpdate'])
    end
    if datos['estado'] == 'ACTIVE'
      publicar(id)
      preparar_para_web(id)
    end
    id
  end

  # Para que salga en el menú de la web tiene que estar en una colección (etiqueta prendas, accesorios u outlet),
  # y ya no está «pendiente de stock».
  def self.preparar_para_web(id)
    tags = gql('query t($id: ID!) { product(id: $id) { tags } }', id: id)['product']['tags']
    unless (tags & %w[prendas accesorios outlet]).any?
      ok!(gql('mutation a($id: ID!, $tags: [String!]!) { tagsAdd(id: $id, tags: $tags) { userErrors { field message } } }',
              id: id, tags: ['prendas'])['tagsAdd'])
    end
    if tags.include?('stock-pendiente')
      ok!(gql('mutation q($id: ID!, $tags: [String!]!) { tagsRemove(id: $id, tags: $tags) { userErrors { field message } } }',
              id: id, tags: ['stock-pendiente'])['tagsRemove'])
    end
  end

  def self.subir_foto(id, nombre, mime, bytes, alt)
    destino = ok!(gql('mutation subida($input: [StagedUploadInput!]!) { stagedUploadsCreate(input: $input) { stagedTargets { url resourceUrl } userErrors { field message } } }',
                      input: [{ resource: 'IMAGE', filename: nombre, mimeType: mime, httpMethod: 'PUT' }])['stagedUploadsCreate'])['stagedTargets'].first
    uri = URI(destino['url'])
    put = Net::HTTP::Put.new(uri, 'Content-Type' => mime)
    put.body = bytes
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 120) { |h| h.request(put) }
    raise ErrorPanel.new("No se ha podido subir la foto (#{res.code})", 502) unless res.code.start_with?('2')
    ok!(gql('mutation foto($product: ProductUpdateInput!, $media: [CreateMediaInput!]) { productUpdate(product: $product, media: $media) { product { id } userErrors { field message } } }',
            product: { id: id }, media: [{ originalSource: destino['resourceUrl'], mediaContentType: 'IMAGE', alt: alt }])['productUpdate'])
    id
  end

  def self.ventas
    desde = (Time.now - 60 * 86_400).strftime('%Y-%m-%d')
    d = gql(<<~Q, q: "created_at:>=#{desde}")
      query ventas($q: String) { orders(first: 100, sortKey: CREATED_AT, reverse: true, query: $q) { nodes {
        id name createdAt displayFinancialStatus sourceName totalPriceSet { shopMoney { amount } }
        lineItems(first: 30) { nodes { title variantTitle quantity sku } } } } }
    Q
    d['orders']['nodes'].map do |o|
      {
        'id' => o['id'], 'numero' => o['name'], 'fecha' => o['createdAt'], 'estado' => o['displayFinancialStatus'],
        'canal' => o['sourceName'], 'total' => o['totalPriceSet']['shopMoney']['amount'].to_f,
        'lineas' => o['lineItems']['nodes'].map { |l| { 'titulo' => l['title'], 'variante' => l['variantTitle'], 'cantidad' => l['quantity'], 'sku' => l['sku'] } }
      }
    end
  end
end

# ---------- modo demo: los mismos datos, guardados solo en memoria ----------
module Demo
  @productos = JSON.parse(File.read(File.join(DIR, 'datos-demo.json'), encoding: 'utf-8')) rescue []
  @mutex = Mutex.new

  def self.contexto
    { 'tienda' => 'Otxaran (demo)', 'dominio' => nil, 'admin' => nil,
      'ubicacion' => { 'name' => 'Soraluce Kalea 8, Zumarraga' }, 'publicaciones' => [] }
  end

  def self.productos
    @productos
  end

  def self.producto(id)
    @productos.find { |p| p['id'] == id } or raise ErrorPanel.new('No encuentro esa prenda', 404)
  end

  def self.poner_stock(item, cantidad, anterior)
    @mutex.synchronize do
      v = @productos.flat_map { |p| p['variantes'] }.find { |x| x['item'] == item } or raise ErrorPanel.new('Talla no encontrada', 404)
      raise ErrorPanel.new('El stock de esta talla ha cambiado mientras tanto. He recargado los datos: vuelve a mirarlo.', 409) if anterior && v['stock'] != anterior
      v['stock'] = cantidad
    end
    { 'stock' => cantidad }
  end

  def self.crear(datos)
    @mutex.synchronize do
      id = "demo/Product/#{Time.now.to_f}"
      @productos.unshift(
        'id' => id, 'handle' => '', 'titulo' => datos['titulo'], 'estado' => datos['estado'], 'tipo' => datos['tipo'],
        'marca' => datos['marca'], 'etiquetas' => datos['etiquetas'], 'descripcion' => datos['descripcion'].to_s, 'url' => nil,
        'fotos' => [], 'opciones' => [{ 'nombre' => 'Talla', 'valores' => datos['tallas'] }],
        'variantes' => datos['tallas'].map.with_index do |t, i|
          { 'id' => "#{id}/v#{i}", 'titulo' => t, 'sku' => "#{datos['sku']}-#{t.upcase.delete(' ')}", 'precio' => datos['precio'].to_f,
            'opciones' => { 'Talla' => t }, 'item' => "#{id}/i#{i}", 'stock' => datos['stock'][t].to_i }
        end
      )
      id
    end
  end

  def self.editar(id, datos)
    @mutex.synchronize do
      p = producto(id)
      { 'titulo' => 'titulo', 'tipo' => 'tipo', 'marca' => 'marca', 'descripcion' => 'descripcion', 'estado' => 'estado' }.each do |k, campo|
        p[campo] = datos[k] if datos.key?(k)
      end
      p['variantes'].each { |v| v['precio'] = datos['precio'].to_f } if datos.key?('precio')
    end
    id
  end

  def self.subir_foto(id, _nombre, mime, bytes, _alt)
    require 'base64'
    @mutex.synchronize do
      producto(id)['fotos'] << { 'id' => "demo/foto/#{Time.now.to_f}", 'url' => "data:#{mime};base64,#{Base64.strict_encode64(bytes)}" }
    end
    id
  end

  def self.ventas
    []
  end
end

BACKEND = MODO == 'shopify' ? Shopify : Demo

# El servidor junta las dos barras de «gid://» al leer la dirección: se recuperan aquí
def id_de_ruta(trozo)
  URI.decode_www_form_component(trozo).sub(%r{\Agid:/+}, "gid://")
end

# ---------- validación de lo que llega del panel ----------
def validar_producto!(d, nuevo)
  if nuevo || d.key?('titulo')
    raise ErrorPanel.new('Falta el nombre de la prenda') if d['titulo'].to_s.strip.empty?
    d['titulo'] = d['titulo'].strip
  end
  if nuevo || d.key?('precio')
    precio = d['precio'].to_s.tr(',', '.').to_f
    raise ErrorPanel.new('El precio tiene que ser mayor que 0') unless precio > 0
    d['precio'] = precio
  end
  raise ErrorPanel.new('Tipo de prenda no válido') if (nuevo || d.key?('tipo')) && !TIPOS.include?(d['tipo'])
  raise ErrorPanel.new('Estado no válido') if (nuevo || d.key?('estado')) && !%w[ACTIVE DRAFT ARCHIVED].include?(d['estado'])
  if nuevo
    d['tallas'] = Array(d['tallas']).map(&:to_s).map(&:strip).reject(&:empty?).uniq
    raise ErrorPanel.new('Elige al menos una talla') if d['tallas'].empty?
    d['stock'] = (d['stock'] || {}).map { |k, v| [k, [v.to_i, 0].max] }.to_h
    d['marca'] = d['marca'].to_s.strip.empty? ? 'Otxaran' : d['marca'].strip
    d['etiquetas'] = [d['tipo'] == 'Accesorios' ? 'accesorios' : 'prendas']
    raise ErrorPanel.new('Falta el código (SKU)') unless d['sku'].to_s =~ /\A[A-Z0-9-]+\z/
  end
  d
end

# ---------- servidor web ----------
def responder(res, estado, cuerpo)
  res.status = estado
  res['Content-Type'] = 'application/json; charset=utf-8'
  res['Cache-Control'] = 'no-store'
  res.body = JSON.generate(cuerpo)
end

def autorizado?(req, res)
  return true if CLAVE.empty?
  WEBrick::HTTPAuth.basic_auth(req, res, 'Panel Otxaran') { |_u, clave| clave == CLAVE }
  true
rescue WEBrick::HTTPStatus::Unauthorized
  res.status = 401
  res['WWW-Authenticate'] = 'Basic realm="Panel Otxaran"'
  false
end

# a partir de aquí, solo si se ejecuta directamente (así prueba.rb puede cargar las funciones)
return unless $PROGRAM_NAME == __FILE__

# Abierto a internet o a la red sin contraseña, cualquiera podría cambiar la tienda: no se arranca
if ABIERTO && CLAVE.length < 8
  abort 'Para abrir el panel en la nube o en la red hace falta CLAVE_PANEL con al menos 8 caracteres.'
end

servidor = WEBrick::HTTPServer.new(
  Port: PUERTO, BindAddress: ABIERTO ? '0.0.0.0' : '127.0.0.1',
  AccessLog: [], Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

servidor.mount_proc('/api/') do |req, res|
  next unless autorizado?(req, res)
  begin
    ruta = req.path.sub(%r{\A/api}, '')
    datos = req.body.to_s.empty? ? {} : JSON.parse(req.body)
    case [req.request_method, ruta]
    when ['GET', '/estado']
      responder(res, 200, 'modo' => MODO, 'contexto' => BACKEND.contexto.reject { |k, _| k == 'publicaciones' }, 'tipos' => TIPOS)
    when ['GET', '/productos']
      responder(res, 200, 'productos' => BACKEND.productos)
    when ['POST', '/stock']
      cantidad = Integer(datos['cantidad']) rescue raise(ErrorPanel.new('La cantidad tiene que ser un número'))
      raise ErrorPanel.new('El stock no puede ser negativo') if cantidad < 0
      responder(res, 200, BACKEND.poner_stock(datos['item'].to_s, cantidad, datos['anterior'] && datos['anterior'].to_i))
    when ['POST', '/productos']
      id = BACKEND.crear(validar_producto!(datos, true))
      responder(res, 200, 'producto' => BACKEND.producto(id))
    when ['GET', '/ventas']
      responder(res, 200, 'ventas' => BACKEND.ventas)
    else
      if req.request_method == 'POST' && ruta =~ %r{\A/productos/(.+)/fotos\z}
        id = id_de_ruta(Regexp.last_match(1))
        mime = datos['tipo'].to_s
        raise ErrorPanel.new('Solo se pueden subir fotos JPG, PNG o WebP') unless %w[image/jpeg image/png image/webp].include?(mime)
        require 'base64'
        bytes = Base64.decode64(datos['datos'].to_s)
        raise ErrorPanel.new('La foto está vacía') if bytes.empty?
        raise ErrorPanel.new('La foto pesa demasiado (máx. 15 MB)') if bytes.bytesize > 15_000_000
        p = BACKEND.producto(id)
        nombre = "#{p['handle'].to_s.empty? ? 'prenda' : p['handle']}-#{Time.now.to_i}.#{mime.split('/').last.sub('jpeg', 'jpg')}"
        BACKEND.subir_foto(id, nombre, mime, bytes, p['titulo'])
        responder(res, 200, 'producto' => BACKEND.producto(id))
      elsif req.request_method == 'POST' && ruta =~ %r{\A/productos/(.+)\z}
        id = id_de_ruta(Regexp.last_match(1))
        BACKEND.editar(id, validar_producto!(datos, false))
        responder(res, 200, 'producto' => BACKEND.producto(id))
      else
        responder(res, 404, 'error' => 'Ruta desconocida')
      end
    end
  rescue ErrorPanel => e
    responder(res, e.estado, 'error' => e.message)
  rescue JSON::ParserError
    responder(res, 400, 'error' => 'Datos mal formados')
  rescue StandardError => e
    warn "#{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    responder(res, 500, 'error' => "Error inesperado: #{e.message}")
  end
end

servidor.mount_proc('/') do |req, res|
  next unless autorizado?(req, res)
  if req.path == '/' || req.path == '/index.html'
    res['Content-Type'] = 'text/html; charset=utf-8'
    res.body = File.read(File.join(DIR, 'public', 'index.html'))
  elsif req.path.start_with?('/fotos-demo/') && MODO == 'demo'
    ruta = File.expand_path(File.join(DIR, '..', 'shopify', 'fotos', req.path.sub('/fotos-demo/', '')))
    if ruta.start_with?(File.expand_path(File.join(DIR, '..', 'shopify', 'fotos'))) && File.file?(ruta)
      res['Content-Type'] = 'image/jpeg'
      res.body = File.binread(ruta)
    else
      res.status = 404
    end
  else
    res.status = 404
    res.body = 'No encontrado'
  end
end

trap('INT') { servidor.shutdown }
trap('TERM') { servidor.shutdown }
puts "Panel de Otxaran en http://localhost:#{PUERTO}  (modo: #{MODO == 'demo' ? 'DEMO, sin guardar en Shopify' : "Shopify, tienda #{TIENDA}"})"
puts 'Para pararlo: Ctrl+C'
servidor.start
