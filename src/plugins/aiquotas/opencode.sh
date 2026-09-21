#!/usr/bin/env bash
# =============================================================================
# aiquotas adapter — opencode (OpenCode Go subscription)
# =============================================================================
# Companion adapter for the aiquotas plugin. Provides _aiquotas_collect_opencode
# which emits a canonical metrics document for the OpenCode Go plan usage
# windows.
#
# Loaded lazily by _aiquotas_load_provider in the entry point. NEVER source this
# file directly — go through the loader.
#
# Endpoint: GET https://opencode.ai/zen/go/v1/usage
# Auth:     Authorization: Bearer <OpenCode Zen API key, "sk-...">
# Shape:    {usage:{rolling:{status,percent,resetsAt},
#                   weekly :{status,percent,resetsAt},
#                   monthly:{status,percent,resetsAt}}}
#           percent = % CONSUMED; remaining% = 100 - percent.
#
# --- On the endpoint being undocumented -------------------------------------
#
# https://opencode.ai/docs/go/ documents no usage API at all and points users at
# the web console instead. The route nonetheless exists and was verified against
# the live service: it answers 401 with a JSON AuthError when unauthenticated,
# where every sibling path under /zen/ falls through to the marketing site's
# 404. Two upstream feature requests (anomalyco/opencode#16017, #31084) propose
# a *different*, dollar-denominated shape; that shape is the issue authors'
# invention and does not match what the service returns. The normalization in
# emit_opencode follows the observed response and degrades to `unsupported`
# rather than guessing if the shape changes, which is the right outcome for an
# endpoint carrying no compatibility promise.
#
# Only status "ok" has been observed in the wild, so the per-window `status`
# field is deliberately not interpreted; health comes from `percent` via the
# shared threshold evaluator like every other provider.
#
# --- The monthly window ------------------------------------------------------
#
# The plan meters three windows but a canonical record holds exactly one
# interval plus one weekly percentage, so `monthly` is dropped, the same way
# emit_claudecode drops weekly_scoped. Monthly is arguably the window that
# actually governs a $10/month plan, so surfacing it needs either a second
# record or a monthly_remaining_percent dimension — both contract-level changes,
# deliberately left as a follow-up.
# =============================================================================

POWERKIT_ROOT="${POWERKIT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
. "${POWERKIT_ROOT}/src/core/guard.sh"
source_guard "aiquotas_opencode" && return 0

# -----------------------------------------------------------------------------
# Key resolution
# -----------------------------------------------------------------------------
# OPENCODE_API_KEY wins when set. That is opencode's own environment variable
# for the Zen key, not one invented here, so exporting it in a shell profile is
# the configuration that works everywhere tmux inherits the environment.
# Otherwise read ["opencode-go"].key out of opencode's auth store, the same way
# the openai adapter reads the Codex OAuth file.
#
# Unlike the Claude OAuth access token, this is a long-lived API key, so there
# is no refresh treadmill and no expected intermittent unauthorized window.
#
# Prints the key on stdout, or nothing when none can be resolved.
_aiquotas_opencode_key() {
    if [[ -n "${OPENCODE_API_KEY:-}" ]]; then
        printf '%s' "$OPENCODE_API_KEY"
        return 0
    fi

    local auth
    auth=$(get_option "opencode_auth_file")
    # tmux option values are not shell-expanded, so a leading ~/ is literal.
    # Only the bare-home form is expanded; ~user/... is left untouched rather
    # than being silently rewritten under the current $HOME.
    if [[ "$auth" == "~" ]]; then
        auth="$HOME"
    elif [[ "$auth" == \~/* ]]; then
        auth="${HOME}/${auth#\~/}"
    fi
    [[ -n "$auth" && -r "$auth" ]] || return 0

    jq -r '.["opencode-go"].key // empty' "$auth" 2>/dev/null
}

# -----------------------------------------------------------------------------
# OpenCode Go adapter
# -----------------------------------------------------------------------------
#
# Reads the Go plan usage endpoint and emits one quota record for the rolling
# window, with the weekly window as a dimension. Treats the data as `official`
# only when a key could be resolved.
#
# Returns the canonical JSON document on stdout. Exits 0 even on partial
# failure (the provider_outcomes entry carries the error); exits non-zero only
# when jq cannot assemble the envelope at all.
#
_aiquotas_collect_opencode() {
    local key
    key=$(_aiquotas_opencode_key)

    if [[ -z "$key" ]]; then
        jq -nc '
            {schema_version:1, records:[],
             provider_outcomes:[{provider:"opencode",source:"official",
                                 status:"unconfigured",
                                 error:"no OpenCode key: set OPENCODE_API_KEY or subscribe to Go in opencode"}]}
        '
        return 0
    fi

    local url timeout body status
    url=$(get_option "opencode_usage_url")
    timeout=$(get_option "timeout")
    timeout="${timeout:-5}"

    if [[ -z "$url" ]]; then
        jq -nc '
            {schema_version:1, records:[],
             provider_outcomes:[{provider:"opencode",source:"official",
                                 status:"unconfigured",
                                 error:"opencode usage URL not configured"}]}
        '
        return 0
    fi

    # The credential travels via stdin so it never appears in argv.
    body=$(_aiquotas_http_get_meta_authed \
        "$url" "$timeout" \
        "Authorization" "Bearer $key" \
        -H "Accept: application/json") || body=""
    status=$(_aiquotas_last_status)

    if [[ -z "$body" ]]; then
        jq -nc '
            {schema_version:1, records:[],
             provider_outcomes:[{provider:"opencode",source:"official",
                                 status:"unavailable",
                                 error:"usage fetch transport failure"}]}
        '
        return 0
    fi

    # A revoked or mistyped key answers 401 with {"type":"error",...}; the
    # shared mapper turns that into `unauthorized` rather than a blank segment.
    if [[ "$status" != 2* ]]; then
        local canonical_status canonical_error
        canonical_status=$(_aiquotas_http_status_to_canonical "$status")
        canonical_error=$(_aiquotas_http_status_error_message "$body" "usage")
        jq -nc \
            --arg st "$canonical_status" \
            --arg er "$canonical_error" \
            '
            {schema_version:1, records:[],
             provider_outcomes:[{provider:"opencode",source:"official",
                                 status:$st, error:$er}]}
            '
        return 0
    fi

    if ! _aiquotas_metrics_document "opencode" "$body" 2>/dev/null; then
        jq -nc '
            {schema_version:1, records:[],
             provider_outcomes:[{provider:"opencode",source:"official",
                                 status:"malformed",
                                 error:"usage payload normalization failed"}]}
        '
        return 0
    fi
}
