# Panel de Otxaran en la nube (Render, Railway, Fly.io…).
# Solo necesita servidor.rb y la carpeta public/. La configuración va en variables de entorno, nunca en un archivo .env subido.
FROM ruby:3.3-slim
WORKDIR /app
RUN gem install webrick --no-document
COPY servidor.rb ./
COPY public ./public
ENV LANG=C.UTF-8
CMD ["ruby", "servidor.rb"]
