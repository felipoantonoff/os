# Base stage: OS packages, nginx, mise, and shared configuration.
FROM docker.io/debian:trixie-slim AS base

WORKDIR /infinite

RUN apt-get update && apt-get upgrade -y \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bind9-dnsutils build-essential ca-certificates certbot cron \
	curl debian-archive-keyring git gnupg2 haveged lsb-release procps rsync supervisor \
	tar tmux unzip vim wget zip unattended-upgrades

RUN curl -sL --proto '=https' --tlsv1.2 "https://nginx.org/keys/nginx_signing.key" | gpg --dearmor >"/usr/share/keyrings/nginx-archive-keyring.gpg" \
	&& echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/debian $(lsb_release -cs) nginx" >"/etc/apt/sources.list.d/nginx.list" \
	&& apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nginx logrotate \
	&& mkdir -p /app/conf/pki \
	&& chown root:nogroup /app \
	&& chmod 1775 /app

RUN curl -sL --proto '=https' --tlsv1.2 "https://mise.run" \
	| MISE_INSTALL_PATH=/usr/local/bin/mise sh \
	&& chmod +x /usr/local/bin/mise \
	&& echo 'eval "$(/usr/local/bin/mise activate bash)"' >>/etc/profile \
	&& echo 'export PATH="$HOME/.local/bin:$PATH"' >>/etc/profile \
	&& echo 'set -as terminal-features ",*:RGB"' >/etc/tmux.conf

ENV MISE_DATA_DIR=/usr/local/share/mise

COPY /container/nginx/root/* /etc/nginx/

COPY --chown=root:root /container/nginx/user/ /app/conf/nginx/

COPY /container/supervisord.conf /infinite/supervisord.conf

# Build stage: generates templ code and compiles the binary without host tooling.
FROM base AS build

COPY . .

ENV PATH="/usr/local/share/mise/shims:${PATH}"

RUN mise trust \
	&& mise install --yes \
	&& go mod download \
	&& templ generate -path src/presentation/ui \
	&& CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o os ./os.go

# Test stage: runs the Go test suite with the build stage toolchain.
FROM build AS test

# Unit tests run without runtime setup, so provide the nginx files it generates.
RUN mkdir -p /app/html /app/logs/nginx \
	&& touch /app/logs/nginx/nginx.log \
	&& chown -R nobody:nogroup /app/html /app/logs \
	&& openssl dhparam -dsaparam -out /etc/nginx/dhparam.pem 2048

ENTRYPOINT ["go", "test", "-v", "./..."]

# Runtime stage: ships the prebuilt binary and starts supervisord.
# NOSONAR - supervisord runs as root on purpose: it binds privileged ports and manages system services (nginx, cron, sshd, certbot)
FROM base AS runtime

RUN cp /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/52unattended-upgrades-local \
  && sed -i '/codename=\${distro_codename}-security,label=Debian-Security";/a\\        "origin=nginx,archive=stable,label=nginx";' /etc/apt/apt.conf.d/52unattended-upgrades-local \
  && grep -q 'origin=nginx,archive=stable,label=nginx' /etc/apt/apt.conf.d/52unattended-upgrades-local || (echo "ErrorEditingUnattendedUpgradesConfigFile" && exit 1)

COPY --from=build /infinite/os /infinite/os

RUN chmod +x /infinite/os \
	&& ln -s /infinite/os /usr/bin/os

EXPOSE 22/tcp 80/tcp 443/tcp 3306/tcp 5432/tcp 6379/tcp 1618/tcp

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/infinite/supervisord.conf"]
