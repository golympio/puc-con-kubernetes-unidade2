# Build a partir da raiz da entrega (contexto = puc-con-kubernetes-unidade2/).
# Empacota o backend Flask do guess_game SEM alterar o codigo-fonte. No
# Kubernetes esta imagem sobe atras do Deployment con-guess-backend; as
# variaveis FLASK_DB_* chegam via ConfigMap/Secret (k8s/), nao pelo Dockerfile.
FROM python:3.12-slim

WORKDIR /app

COPY guess_game/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY guess_game/run.py ./run.py
COPY guess_game/guess ./guess
COPY guess_game/repository ./repository

ENV FLASK_APP=run.py
EXPOSE 5000

CMD ["flask", "run", "--host=0.0.0.0", "--port=5000"]
