include .env
export

.PHONY: hosts certs up tools-up down logs ps

hosts:
	@for h in $(HOST_NAME) $(ADMINER_HOST); do \
		grep -q " $$h$$" /etc/hosts || sudo bash -c "echo 0.0.0.0 $$h >> /etc/hosts"; \
		echo "hosts entry OK for $$h"; \
	done

certs:
	mkdir -p certs
	mkcert -install
	mkcert -cert-file certs/local-cert.pem -key-file certs/local-key.pem $(HOST_NAME) $(ADMINER_HOST)

up:
	docker compose up -d

tools-up:
	docker compose --profile tools up -d

down:
	docker compose --profile tools down

logs:
	docker compose logs -f

ps:
	docker compose ps
