# Build a partir da raiz da entrega (contexto = puc-con-kubernetes-unidade2/).
# Estagio 1: build estatico do React. REACT_APP_BACKEND_URL vazio faz o
# frontend chamar caminhos relativos (mesma origem), que o NGINX do estagio
# final encaminha para o upstream do backend — sem host fixo embutido.
FROM node:18 AS build

WORKDIR /app

COPY guess_game/frontend/package.json guess_game/frontend/package-lock.json ./
RUN npm install

COPY guess_game/frontend/ ./
ENV REACT_APP_BACKEND_URL=""
RUN npm run build

# Estagio 2: serve o build com NGINX (tambem atua como proxy reverso/LB).
# O upstream aponta para o Service do backend (con-guess-backend:5000), que
# balanceia entre os Pods — adaptacao de implantacao para o Kubernetes.
FROM nginx:1.27-alpine

COPY --from=build /app/build /usr/share/nginx/html
COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
