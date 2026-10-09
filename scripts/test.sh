#!/usr/bin/env bash
# =====================================================================
#  test.sh <image> -- tests fonctionnels de haproxy-hardened
#
#  Lance l'image comme en production : rootfs en lecture seule, aucune
#  capacite, no-new-privileges, tmpfs sur /tmp et /run/haproxy, conf montee
#  en lecture seule. Prouve ce que l'image doit savoir faire, pas seulement
#  qu'un port est ouvert :
#    1. le healthcheck de l'image (monitor-uri) ;
#    2. une reponse HTTP ;
#    3. une terminaison TLS reelle (OpenSSL + providers dans FROM scratch) ;
#    4. une ACL a expression reguliere (PCRE2) ;
#    5. une configuration cassee EMPECHE le demarrage (validation de l'init).
# =====================================================================
set -euo pipefail

IMAGE="${1:?usage: test.sh <image>}"
NOM="haproxy-test-$$"
TMP=$(mktemp -d)
chmod 755 "$TMP"
trap 'docker rm -f "$NOM" "$NOM-ko" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

ok()  { printf '  OK     %s\n' "$*"; }
ko()  { printf '  ECHEC  %s\n' "$*" >&2; docker logs "$NOM" 2>&1 | tail -20 >&2 || true; exit 1; }

# Certificat jetable (cle + chaine dans un seul PEM, format HAProxy).
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=test.local" \
  -keyout "$TMP/k.pem" -out "$TMP/c.pem" >/dev/null 2>&1
cat "$TMP/c.pem" "$TMP/k.pem" > "$TMP/test.pem"
chmod 644 "$TMP/test.pem"

cat > "$TMP/haproxy.cfg" <<'CFG'
global
    log stdout format raw local0 info
    stats socket /run/haproxy/admin.sock mode 600 level admin expose-fd listeners
defaults
    mode http
    timeout connect 5s
    timeout client  10s
    timeout server  10s
frontend healthz
    bind 127.0.0.1:8405
    monitor-uri /healthz
frontend web
    bind :8080
    bind :8443 ssl crt /usr/local/etc/haproxy/test.pem
    acl api path -m reg ^/api/v[0-9]+/
    http-request return status 200 content-type text/plain string "regex" if api
    http-request return status 200 content-type text/plain string "tls" if { ssl_fc }
    http-request return status 200 content-type text/plain string "http"
CFG
chmod 644 "$TMP/haproxy.cfg"

run() {  # <nom> <repertoire de conf>
  docker run -d --name "$1" \
    --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --tmpfs /tmp:mode=1777 --tmpfs /run/haproxy:mode=0750,uid=4430,gid=4430 \
    -v "$2:/usr/local/etc/haproxy:ro" \
    -p 127.0.0.1::8080 -p 127.0.0.1::8443 \
    "$IMAGE" >/dev/null
}

echo "== $IMAGE"
run "$NOM" "$TMP"
for _ in $(seq 1 30); do
  docker exec "$NOM" /usr/local/bin/init --healthcheck >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$NOM" /usr/local/bin/init --healthcheck >/dev/null 2>&1 || ko "healthcheck"
ok "healthcheck (monitor-uri)"

HTTP=$(docker port "$NOM" 8080/tcp | head -1)
HTTPS=$(docker port "$NOM" 8443/tcp | head -1)

[ "$(curl -fsS --noproxy '*' "http://$HTTP/")" = "http" ] || ko "HTTP"
ok "HTTP"

[ "$(curl -fsS --noproxy '*' -k "https://$HTTPS/")" = "tls" ] || ko "TLS"
proto=$(curl -sS --noproxy '*' -k -o /dev/null -w '%{ssl_verify_result} %{http_version}' "https://$HTTPS/")
ok "TLS (curl : $proto)"

[ "$(curl -fsS --noproxy '*' "http://$HTTP/api/v2/x")" = "regex" ] || ko "ACL PCRE2"
[ "$(curl -fsS --noproxy '*' "http://$HTTP/api/vX/x")" = "http" ] || ko "ACL PCRE2 (negatif)"
ok "ACL a expression reguliere (PCRE2)"

# Sortie capturee AVANT le grep : avec pipefail, `| grep -q` sort a la 1re
# correspondance (USE_OPENSSL, ligne 2) et `haproxy -vv` meurt de SIGPIPE
# (141) s'il ecrit encore -- echec aleatoire (PR #2, 2026-10-09).
VV=$(docker exec "$NOM" haproxy -vv 2>/dev/null)
grep -q 'OpenSSL' <<<"$VV" || ko "haproxy -vv sans OpenSSL"
ok "$(head -1 <<<"$VV" | cut -c1-60)"

# Une configuration cassee ne doit PAS demarrer.
mkdir -p "$TMP/ko"
printf 'global\nfrontend x\n    bind :8080\n    directive-inconnue\n' > "$TMP/ko/haproxy.cfg"
chmod 644 "$TMP/ko/haproxy.cfg"; chmod 755 "$TMP/ko"
run "$NOM-ko" "$TMP/ko"
for _ in $(seq 1 15); do
  [ "$(docker inspect -f '{{.State.Status}}' "$NOM-ko")" = exited ] && break
  sleep 1
done
[ "$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$NOM-ko")" = "exited 1" ] \
  || ko "une configuration cassee a demarre"
ok "configuration cassee refusee au demarrage"

echo "== tous les tests passent"
