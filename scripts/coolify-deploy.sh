#!/usr/bin/env bash
#
# Call a Coolify Deploy Webhook and decide whether the job passes.
#
# Shared by the root action and by coolify-deploy/action.yml so the two cannot
# drift; a composite action cannot `uses:` a sibling action by relative path,
# but both can run the same script out of $GITHUB_ACTION_PATH.
#
# Reads   WEBHOOK_URL TOKEN FORCE RETRIES FAIL_ON_ERROR
# Writes  status= and outcome= to $GITHUB_OUTPUT

# No -e: every failure here is handled explicitly, and an unhandled exit would
# skip the two lines that record what happened.
set -uo pipefail

WEBHOOK_URL="${WEBHOOK_URL:-}"
TOKEN="${TOKEN:-}"
FORCE="${FORCE:-true}"
RETRIES="${RETRIES:-2}"
FAIL_ON_ERROR="${FAIL_ON_ERROR:-true}"

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s\n' "$*" >> "$GITHUB_OUTPUT"; fi
}

fail() {
  emit "outcome=failed"
  echo "::error::$*"
  if [ "$FAIL_ON_ERROR" = true ]; then exit 1; fi
  exit 0
}

if [ -z "$WEBHOOK_URL" ]; then
  fail "coolify webhook URL is empty."
fi
if [ -z "$TOKEN" ]; then
  fail "coolify token is empty. Create one under Keys & Tokens -> API tokens in Coolify and pass it in."
fi

# Coolify only re-pulls a mutable tag -- latest, main -- when the deploy is
# forced. Without this a successful HTTP 200 can still leave the old container
# running, which is the single most confusing way for this to go wrong.
url="$WEBHOOK_URL"
if [ "$FORCE" = true ]; then
  case "$url" in
    *[?\&]force=*) ;;                        # caller already decided
    *\?*)          url="$url&force=true" ;;
    *)             url="$url?force=true" ;;
  esac
fi

attempt=0
status=000
rc=0
while : ; do
  attempt=$((attempt + 1))
  body="$(mktemp)"

  # Deliberately not --fail, which throws the response body away. Coolify puts
  # the actual cause in there -- an unknown UUID, a token scoped to another
  # team and a missing permission all surface as the same bare 404.
  # POST, always. Coolify's deploy webhook used to accept GET too and now
  # answers it with a wrong-method error, so there is nothing to configure.
  status="$(curl --silent --show-error \
    --request POST "$url" \
    --header "Authorization: Bearer $TOKEN" \
    --output "$body" --write-out '%{http_code}' \
    --connect-timeout 10 --max-time 120)"
  rc=$?
  status="${status:-000}"

  echo "HTTP $status (attempt $attempt of $((RETRIES + 1)))"
  if [ -s "$body" ]; then
    head -c 4000 "$body"
    echo
  fi
  rm -f "$body"

  # A 4xx is a real answer: the URL, the token or the app is wrong, and asking
  # again will not change it. Retry only what might be transient.
  if [ "$rc" -eq 0 ] && [ "$status" != 429 ] && [ "$status" -lt 500 ]; then break; fi
  if [ "$attempt" -gt "$RETRIES" ]; then break; fi

  delay=$((attempt * 5))
  echo "retrying in ${delay}s"
  sleep "$delay"
done

emit "status=$status"

# curl's own failure has to be checked before the status: a DNS or TLS error
# leaves http_code at 000, which sails straight through a `>= 400` test.
if [ "$rc" -ne 0 ]; then
  fail "could not reach the Coolify webhook (curl exit $rc). Check the host and that the URL starts with https://."
fi
if [ "$status" -ge 400 ]; then
  fail "Coolify redeploy failed with HTTP $status (see the response body above)."
fi

emit "outcome=success"
echo "Coolify accepted the redeploy."
