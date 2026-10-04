.PHONY: help build up down logs ps test check clean

DC := docker compose

help:
	@echo "Cibles disponibles :"
	@echo "  make build   - Build de l'image (versions lues dans versions.json)"
	@echo "  make up      - Demarre le conteneur"
	@echo "  make down    - Arrete le conteneur"
	@echo "  make test    - Tests fonctionnels (scripts/test.sh)"
	@echo "  make check   - Controle de versions.json (comme le job lint)"

# Memes versions que la CI, par le meme generateur : le Dockerfile n'a aucune
# valeur par defaut et echoue au garde sans build-arg. Un echec du generateur
# arrete la recette (pas de $(shell ...), qui l'avalerait).
build:
	@args=$$(./scripts/versions-build-args.py --docker) \
	  && echo "Build depuis versions.json : $$args" \
	  && DOCKER_BUILDKIT=1 docker build --pull $$args -t docker.io/jbsky/haproxy-hardened:latest .

up:
	$(DC) up -d

down:
	$(DC) down

logs:
	$(DC) logs -f --tail=200

ps:
	$(DC) ps

test:
	./scripts/test.sh "$${IMAGE:-docker.io/jbsky/haproxy-hardened:latest}"

check:
	./scripts/versions-build-args.py --check
	python3 -m unittest discover -s scripts -p 'test_*.py'
