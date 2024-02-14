#!/bin/bash
set -e

NGINX_LANDING_INDEX_HTML=/usr/share/nginx/html/index.html

NGINX_TEMPLATES_DIR=/etc/nginx/templates
NGINX_CONFD_DIR=/etc/nginx/conf.d

# set up for HTTPS/HTTP and NGINX HTTP basic vs. LDAP/LDAPS/LDAP+StartTLS auth

# "include" file that sets 'ssl on' and indicates the locations of the PEM files
NGINX_SSL_ON_CONF=/etc/nginx/nginx_ssl_on_config.conf
# "include" file that sets 'ssl off'
NGINX_SSL_OFF_CONF=/etc/nginx/nginx_ssl_off_config.conf
# "include" symlink name which, at runtime, will point to either the ON of OFF file
NGINX_SSL_CONF=/etc/nginx/nginx_ssl_config.conf

# a blank file just to use as an "include" placeholder for the nginx's LDAP config when LDAP is not used
NGINX_BLANK_CONF=/etc/nginx/nginx_blank.conf

# "include" file for auth_basic, prompt, and htpasswd location
NGINX_BASIC_AUTH_CONF=/etc/nginx/nginx_auth_basic.conf

# "include" file for auth_ldap, prompt, and "auth_ldap_servers" name
NGINX_LDAP_AUTH_CONF=/etc/nginx/nginx_auth_ldap.conf

# "include" file for fully disabling authentication
NGINX_NO_AUTH_CONF=/etc/nginx/nginx_auth_disabled.conf

# volume-mounted user configuration containing "ldap_server ad_server" section with URL, binddn, etc.
NGINX_LDAP_USER_CONF=/etc/nginx/nginx_ldap.conf

# runtime "include" file for auth method (link to either NGINX_BASIC_AUTH_CONF or NGINX_LDAP_AUTH_CONF)
NGINX_RUNTIME_AUTH_CONF=/etc/nginx/nginx_auth_rt.conf

# runtime "include" file for ldap config (link to either NGINX_BLANK_CONF or (possibly modified) NGINX_LDAP_USER_CONF)
NGINX_RUNTIME_LDAP_CONF=/etc/nginx/nginx_ldap_rt.conf

# "include" files for idark2dash rewrite using opensearch dashboards, kibana, and runtime copy, respectively
NGINX_DASHBOARDS_IDARK2DASH_REWRITE_CONF=/etc/nginx/nginx_idark2dash_rewrite_dashboards.conf
NGINX_KIBANA_IDARK2DASH_REWRITE_CONF=/etc/nginx/nginx_idark2dash_rewrite_kibana.conf
NGINX_RUNTIME_IDARK2DASH_REWRITE_CONF=/etc/nginx/nginx_idark2dash_rewrite_rt.conf
# do the same thing for /dashboards URLs, send to kibana if they're using elasticsearch
NGINX_DASHBOARDS_DASHBOARDS_REWRITE_CONF=/etc/nginx/nginx_dashboards_rewrite_dashboards.conf
NGINX_KIBANA_DASHBOARDS_REWRITE_CONF=/etc/nginx/nginx_dashboards_rewrite_kibana.conf
NGINX_RUNTIME_DASHBOARDS_REWRITE_CONF=/etc/nginx/nginx_dashboards_rewrite_rt.conf

# config file for stunnel if using stunnel to issue LDAP StartTLS function
STUNNEL_CONF=/etc/stunnel/stunnel.conf

CA_TRUST_HOST_DIR=/var/local/ca-trust
CA_TRUST_RUN_DIR=/var/run/ca-trust

# copy trusted CA certs to runtime directory and c_rehash them to create symlinks
STUNNEL_CA_PATH_LINE=""
STUNNEL_VERIFY_LINE=""
STUNNEL_CHECK_HOST_LINE=""
STUNNEL_CHECK_IP_LINE=""
NGINX_LDAP_CA_PATH_LINE=""
NGINX_LDAP_CHECK_REMOTE_CERT_LINE=""
mkdir -p "$CA_TRUST_RUN_DIR"
# attempt to make sure trusted CA certs dir is readable by unprivileged nginx worker
chmod 755 "$CA_TRUST_RUN_DIR" || true
CA_FILES=$(shopt -s nullglob dotglob; echo "$CA_TRUST_HOST_DIR"/*)
if (( ${#CA_FILES} )) ; then
  rm -f "$CA_TRUST_RUN_DIR"/*
  pushd "$CA_TRUST_RUN_DIR" >/dev/null 2>&1
  if cp "$CA_TRUST_HOST_DIR"/* ./ ; then

    # attempt to make sure trusted CA certs are readable by unprivileged nginx worker
    chmod 644 * || true

    # create hash symlinks
    c_rehash -compat .

    # variables for stunnel config
    STUNNEL_CA_PATH_LINE="CApath = $CA_TRUST_RUN_DIR"
    [[ -n $NGINX_LDAP_TLS_STUNNEL_VERIFY_LEVEL ]] && STUNNEL_VERIFY_LINE="verify = $NGINX_LDAP_TLS_STUNNEL_VERIFY_LEVEL" || STUNNEL_VERIFY_LINE="verify = 2"
    [[ -n $NGINX_LDAP_TLS_STUNNEL_CHECK_HOST ]] && STUNNEL_CHECK_HOST_LINE="checkHost = $NGINX_LDAP_TLS_STUNNEL_CHECK_HOST"
    [[ -n $NGINX_LDAP_TLS_STUNNEL_CHECK_IP ]] && STUNNEL_CHECK_IP_LINE="checkIP = $NGINX_LDAP_TLS_STUNNEL_CHECK_IP"

    # variables for nginx config
    NGINX_LDAP_CA_PATH_LINE="  ssl_ca_dir $CA_TRUST_RUN_DIR;"
    ( [[ -n $NGINX_LDAP_TLS_STUNNEL_CHECK_HOST ]] || [[ -n $NGINX_LDAP_TLS_STUNNEL_CHECK_IP ]] ) && NGINX_LDAP_CHECK_REMOTE_CERT_LINE="  ssl_check_cert on;" || NGINX_LDAP_CHECK_REMOTE_CERT_LINE="  ssl_check_cert off;"
  fi
  popd >/dev/null 2>&1
fi

if [[ -z $NGINX_SSL ]] || [[ "$NGINX_SSL" != "false" ]]; then
  # doing encrypted HTTPS
  ln -sf "$NGINX_SSL_ON_CONF" "$NGINX_SSL_CONF"
else
  # doing unencrypted HTTP (not recommended)
  ln -sf "$NGINX_SSL_OFF_CONF" "$NGINX_SSL_CONF"
fi

if [[ -z $NGINX_BASIC_AUTH ]] || [[ "$NGINX_BASIC_AUTH" == "true" ]]; then
  # doing HTTP basic auth instead of ldap

  # point nginx_auth_rt.conf to nginx_auth_basic.conf
  ln -sf "$NGINX_BASIC_AUTH_CONF" "$NGINX_RUNTIME_AUTH_CONF"

  # ldap configuration is empty
  ln -sf "$NGINX_BLANK_CONF" "$NGINX_RUNTIME_LDAP_CONF"

elif [[ "$NGINX_BASIC_AUTH" == "no_authentication" ]]; then
  # completely disabling authentication (not recommended)

  # point nginx_auth_rt.conf to nginx_auth_disabled.conf
  ln -sf "$NGINX_NO_AUTH_CONF" "$NGINX_RUNTIME_AUTH_CONF"

  # ldap configuration is empty
  ln -sf "$NGINX_BLANK_CONF" "$NGINX_RUNTIME_LDAP_CONF"

else
  # ldap authentication

  # point nginx_auth_rt.conf to nginx_auth_ldap.conf
  ln -sf "$NGINX_LDAP_AUTH_CONF" "$NGINX_RUNTIME_AUTH_CONF"

  # parse URL information out of user ldap configuration
  # example:
  #   url "ldap://localhost:3268/DC=ds,DC=example,DC=com?sAMAccountName?sub?(objectClass=person)";
  #             "url"    quote protocol h/p    uri
  #             ↓        ↓     ↓        ↓      ↓
  PATTERN='^(\s*url\s+)([''"]?)(\w+)://([^/]+)(/.*)$'

  unset HEADER
  unset OPEN_QUOTE
  unset PROTOCOL
  unset REMOTE_HOST
  unset REMOTE_PORT
  unset URI_TO_END

  URL_LINE_NUM=0
  READ_LINE_NUM=0
  while IFS= read -r LINE; do
    READ_LINE_NUM=$((READ_LINE_NUM+1))
    if [[ $LINE =~ $PATTERN ]]; then
      URL_LINE_NUM=$READ_LINE_NUM
      HEADER=${BASH_REMATCH[1]}
      OPEN_QUOTE=${BASH_REMATCH[2]}
      PROTOCOL=${BASH_REMATCH[3]}
      REMOTE=${BASH_REMATCH[4]}
      REMOTE_ARR=(${REMOTE//:/ })
      [[ -n ${REMOTE_ARR[0]} ]] && REMOTE_HOST=${REMOTE_ARR[0]}
      [[ -n ${REMOTE_ARR[1]} ]] && REMOTE_PORT=${REMOTE_ARR[1]} || REMOTE_PORT=3268
      URI_TO_END=${BASH_REMATCH[5]}
      break
    fi
  done < "$NGINX_LDAP_USER_CONF"

  if [[ "$NGINX_LDAP_TLS_STUNNEL" == "true" ]]; then
    # user provided LDAP configuration, but we need to tweak it and set up stunnel to issue StartTLS

    if [[ -z $REMOTE_HOST ]]; then
      # missing LDAP info needed to configure tunnel, abort
      exit 1
    fi

    # pick a random local port to listen on for the client side of the tunnel
    read PORT_LOWER POWER_UPPER < /proc/sys/net/ipv4/ip_local_port_range
    LOCAL_PORT=$(shuf -i $PORT_LOWER-$POWER_UPPER -n 1)

    # create PEM key for stunnel (this key doesn't matter as we're only using stunnel in client mode)
    pushd /tmp >/dev/null 2>&1
    openssl genrsa -out key.pem 2048
    openssl req -new -x509 -key key.pem -out cert.pem -days 3650 -subj "/CN=$(hostname)/O=Malcolm/C=US"
    cat key.pem cert.pem > /etc/stunnel/stunnel.pem
    chmod 600 /etc/stunnel/stunnel.pem
    rm -f key.pem cert.pem
    popd >/dev/null 2>&1

    # configure stunnel
    cat <<EOF > "$STUNNEL_CONF"
setuid = nginx
setgid = nginx
pid = /tmp/stunnel.pid
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
client = yes
foreground = yes
cert = /etc/stunnel/stunnel.pem
$STUNNEL_CA_PATH_LINE
$STUNNEL_VERIFY_LINE
$STUNNEL_CHECK_HOST_LINE
$STUNNEL_CHECK_IP_LINE

[stunnel.ldap_start_tls]
accept = localhost:$LOCAL_PORT
connect = $REMOTE_HOST:$REMOTE_PORT
protocol = ldap
EOF

    # rewrite modified copy of user ldap configuration to point to local end of tunnel instead of remote
    rm -f "$NGINX_RUNTIME_LDAP_CONF"
    touch "$NGINX_RUNTIME_LDAP_CONF"
    chmod 600 "$NGINX_RUNTIME_LDAP_CONF"
    READ_LINE_NUM=0
    while IFS= read -r LINE; do
      READ_LINE_NUM=$((READ_LINE_NUM+1))
      if (( $URL_LINE_NUM == $READ_LINE_NUM )); then
        echo "${HEADER}${OPEN_QUOTE}ldap://localhost:${LOCAL_PORT}${URI_TO_END}" >> "$NGINX_RUNTIME_LDAP_CONF"
      else
        echo "$LINE" >> "$NGINX_RUNTIME_LDAP_CONF"
      fi
    done < "$NGINX_LDAP_USER_CONF"

  else
    # we're doing either LDAP or LDAPS, but not StartTLS, so we don't need to use stunnel.
    # however, we do want to set SSL CA trust stuff if specified, so do that
    rm -f "$NGINX_RUNTIME_LDAP_CONF"
    touch "$NGINX_RUNTIME_LDAP_CONF"
    chmod 600 "$NGINX_RUNTIME_LDAP_CONF"
    READ_LINE_NUM=0
    while IFS= read -r LINE; do
      READ_LINE_NUM=$((READ_LINE_NUM+1))
      echo "$LINE" >> "$NGINX_RUNTIME_LDAP_CONF"
      if (( $URL_LINE_NUM == $READ_LINE_NUM )); then
        echo "$NGINX_LDAP_CHECK_REMOTE_CERT_LINE" >> "$NGINX_RUNTIME_LDAP_CONF"
        echo "$NGINX_LDAP_CA_PATH_LINE" >> "$NGINX_RUNTIME_LDAP_CONF"
      fi
    done < "$NGINX_LDAP_USER_CONF"

  fi # stunnel/starttls vs. ldap/ldaps

fi # basic vs. ldap

# if the runtime htpasswd file doesn't exist but the "preseed" does, copy the preseed over for runtime
if [[ ! -f /etc/nginx/auth/htpasswd ]] && [[ -f /tmp/auth/default/htpasswd ]]; then
  cp /tmp/auth/default/htpasswd /etc/nginx/auth/htpasswd
  [[ -n ${PUID} ]] && chown -f ${PUID} /etc/nginx/auth/htpasswd
  [[ -n ${PGID} ]] && chown -f :${PGID} /etc/nginx/auth/htpasswd
  rm -rf /tmp/auth/* || true
fi

# do environment variable substitutions from $NGINX_TEMPLATES_DIR to $NGINX_CONFD_DIR
# NGINX_DASHBOARDS_... are a special case as they have to be crafted a bit based on a few variables
set +e

if [[ "${OPENSEARCH_PRIMARY:-opensearch-local}" == "elasticsearch-remote" ]]; then
  ln -sf "$NGINX_KIBANA_IDARK2DASH_REWRITE_CONF" "$NGINX_RUNTIME_IDARK2DASH_REWRITE_CONF"
  ln -sf "$NGINX_KIBANA_DASHBOARDS_REWRITE_CONF" "$NGINX_RUNTIME_DASHBOARDS_REWRITE_CONF"
else
  ln -sf "$NGINX_DASHBOARDS_IDARK2DASH_REWRITE_CONF" "$NGINX_RUNTIME_IDARK2DASH_REWRITE_CONF"
  ln -sf "$NGINX_DASHBOARDS_DASHBOARDS_REWRITE_CONF" "$NGINX_RUNTIME_DASHBOARDS_REWRITE_CONF"
fi

# first parse DASHBOARDS_URL and assign the resultant urlsplit named tuple to an associative array
#   going to use Python to do so as urllib will do a better job at parsing DASHBOARDS_URL than bash
DASHBOARDS_URL_PARSED="$( ( /usr/bin/env python3 -c "import sys; import json; from urllib.parse import urlsplit; [ sys.stdout.write(json.dumps(urlsplit(line)._asdict()) + '\n') for line in sys.stdin ]" 2>/dev/null <<< "${DASHBOARDS_URL:-http://dashboards:5601/dashboards}" ) | head -n 1 )"
declare -A DASHBOARDS_URL_DICT
for KEY in $(jq -r 'keys[]' 2>/dev/null <<< $DASHBOARDS_URL_PARSED); do
  DASHBOARDS_URL_DICT["$KEY"]=$(jq -r ".$KEY" 2>/dev/null <<< $DASHBOARDS_URL_PARSED)
done

# the "path" from the parsed URL is the dashboards prefix
[[ -z "${NGINX_DASHBOARDS_PREFIX:-}" ]] && \
  [[ -v DASHBOARDS_URL_DICT[path] ]] && \
  NGINX_DASHBOARDS_PREFIX="${DASHBOARDS_URL_DICT[path]}"
# if we failed to get it, use the default
[[ -z "${NGINX_DASHBOARDS_PREFIX:-}" ]] && \
  [[ "${OPENSEARCH_PRIMARY:-opensearch-local}" != "elasticsearch-remote" ]] && \
  NGINX_DASHBOARDS_PREFIX=/dashboards

# the "path" from the parsed URL is the dashboards prefix
if [[ -z "${NGINX_DASHBOARDS_PROXY_PASS:-}" ]]; then
  # if Malcolm is running in anything other than "elasticsearch-remote" mode, then
  #   the dashboards service is already defined in the upstream
  if [[ "${OPENSEARCH_PRIMARY:-opensearch-local}" == "elasticsearch-remote" ]] && [[ -v DASHBOARDS_URL_DICT[scheme] ]] && [[ -v DASHBOARDS_URL_DICT[netloc] ]]; then
    NGINX_DASHBOARDS_PROXY_PASS="${DASHBOARDS_URL_DICT[scheme]}://${DASHBOARDS_URL_DICT[netloc]}"
  else
    NGINX_DASHBOARDS_PROXY_PASS=http://dashboards
  fi
fi
# if we failed to get it, use the default
[[ -z "${NGINX_DASHBOARDS_PROXY_PASS:-}" ]] && \
  [[ "${OPENSEARCH_PRIMARY:-opensearch-local}" != "elasticsearch-remote" ]] && \
  NGINX_DASHBOARDS_PROXY_PASS=http://dashboards

export NGINX_DASHBOARDS_PREFIX
export NGINX_DASHBOARDS_PROXY_PASS
export NGINX_DASHBOARDS_PROXY_URL="$(echo "$(echo "$NGINX_DASHBOARDS_PROXY_PASS" | sed 's@/$@@')/$(echo "$NGINX_DASHBOARDS_PREFIX" | sed 's@^/@@')" | sed 's@/$@@')"

# now process the environment variable substitutions
for TEMPLATE in "$NGINX_TEMPLATES_DIR"/*.conf.template; do
  DOLLAR=$ envsubst < "$TEMPLATE" > "$NGINX_CONFD_DIR/$(basename "$TEMPLATE"| sed 's/\.template$//')"
done

set -e

# insert some build and runtime information into the landing page
if [[ -f "${NGINX_LANDING_INDEX_HTML}" ]]; then
  if [[ "${OPENSEARCH_PRIMARY:-opensearch-local}" == "elasticsearch-remote" ]]; then
    MALCOLM_DASHBOARDS_NAME=Kibana
    MALCOLM_DASHBOARDS_URL="$NGINX_DASHBOARDS_PROXY_URL"
    MALCOLM_DASHBOARDS_ICON=elastic.svg
  else
    MALCOLM_DASHBOARDS_NAME=Dashboards
    MALCOLM_DASHBOARDS_URL="$(echo "$NGINX_DASHBOARDS_PREFIX" | sed 's@/$@@')/"
    MALCOLM_DASHBOARDS_ICON=opensearch_mark_default.svg
  fi
  sed -i "s@MALCOLM_DASHBOARDS_NAME_REPLACER@${MALCOLM_DASHBOARDS_NAME}@g" "${NGINX_LANDING_INDEX_HTML}"
  sed -i "s@MALCOLM_DASHBOARDS_URL_REPLACER@${MALCOLM_DASHBOARDS_URL}@g" "${NGINX_LANDING_INDEX_HTML}"
  sed -i "s@MALCOLM_DASHBOARDS_ICON_REPLACER@${MALCOLM_DASHBOARDS_ICON}@g" "${NGINX_LANDING_INDEX_HTML}"
  sed -i "s/MALCOLM_VERSION_REPLACER/v${MALCOLM_VERSION:-unknown} (${VCS_REVISION:-} @ ${BUILD_DATE:-})/g" "${NGINX_LANDING_INDEX_HTML}"
fi

# some cleanup, if necessary
rm -rf /var/log/nginx/* || true

# start supervisor (which will spawn nginx, stunnel, etc.) or whatever the default command is
exec "$@"
