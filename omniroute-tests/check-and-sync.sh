#!/usr/bin/env bash

set -euo pipefail

BASE_URL="${OMNIROUTE_BASE_URL:-http://127.0.0.1:20128}"
API_KEY="${OMNIROUTE_API_KEY:-}"
TEST_TIMEOUT="${OMNIROUTE_MODEL_TEST_TIMEOUT_SECONDS:-45}"
PARALLELISM="${OMNIROUTE_MODEL_TEST_PARALLELISM:-6}"
MAX_MODELS="${OMNIROUTE_MAX_MODELS_PER_CYCLE:-100}"

TEST_DIR="${HOME}/omniroute-tests"
HISTORY_DIR="${TEST_DIR}/history"

mkdir -p "$HISTORY_DIR"

NOW_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"

REPORT="$HISTORY_DIR/models-$STAMP.tsv"
PASS_LIST="$HISTORY_DIR/pass-models-$STAMP.txt"
COMBO_REPORT="$HISTORY_DIR/combos-$STAMP.txt"

CURL_AUTH=()
if [[ -n "$API_KEY" ]]; then
  CURL_AUTH=(-H "Authorization: Bearer $API_KEY")
fi

echo "============================================================"
echo "OmniRoute model health cycle"
echo "UTC: $NOW_UTC"
echo "============================================================"

curl \
  --silent \
  --show-error \
  --fail \
  --max-time 15 \
  "${CURL_AUTH[@]}" \
  "$BASE_URL/v1/models" > "$TEST_DIR/models.json"

mapfile -t MODELS < <(
  jq -r '
    .data[]?.id
    | select(type == "string")
    | select(contains("/"))
    | select(startswith("auto/") | not)
    | select(. != "coding")
    | select(. != "coding-fast")
    | select(. != "reasoning")
    | select(. != "fast")
  ' "$TEST_DIR/models.json" |
  sort -u |
  head -n "$MAX_MODELS"
)

if [[ "${#MODELS[@]}" -eq 0 ]]; then
  echo "ERROR: No concrete provider/model IDs were found."
  exit 1
fi

echo "Testing ${#MODELS[@]} concrete models..."
printf 'timestamp\tstatus\tlatency_ms\tmodel\n' > "$REPORT"

test_model() {
  local model="$1"
  local key
  local tmp
  local start
  local end
  local elapsed
  local http_code

  key="$(printf '%s' "$model" | sha256sum | cut -d' ' -f1)"
  tmp="$TEST_DIR/.model-$key"

  start="$(date +%s%3N)"

  set +e
  http_code="$(
    curl \
      --silent \
      --show-error \
      --output "$tmp.response" \
      --write-out '%{http_code}' \
      --max-time "$TEST_TIMEOUT" \
      "${CURL_AUTH[@]}" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc \
        --arg model "$model" \
        '{
          model: $model,
          messages: [
            {role: "user", content: "Reply with exactly OK"}
          ],
          max_tokens: 16,
          stream: false
        }')" \
      "$BASE_URL/v1/chat/completions" \
      2>"$tmp.error"
  )"
  local status=$?
  set -e

  end="$(date +%s%3N)"
  elapsed=$((end - start))

  if [[ "$status" -eq 0 && "$http_code" =~ ^2 ]]; then
    printf '%s\tPASS\t%s\t%s\n' \
      "$NOW_UTC" "$elapsed" "$model" >> "$REPORT"
    rm -f "$tmp.response" "$tmp.error"
  else
    printf '%s\tFAIL\t%s\t%s\n' \
      "$NOW_UTC" "$elapsed" "$model" >> "$REPORT"

    {
      echo "MODEL=$model"
      echo "HTTP=$http_code"
      echo "CURL_EXIT=$status"
      echo "ERROR:"
      sed -n '1,12p' "$tmp.error" 2>/dev/null || true
      echo "RESPONSE:"
      sed -n '1,12p' "$tmp.response" 2>/dev/null || true
      echo
    } >> "$TEST_DIR/last-failures.log"

    rm -f "$tmp.response" "$tmp.error"
  fi
}

active=0
for model in "${MODELS[@]}"; do
  test_model "$model" &
  active=$((active + 1))

  if (( active >= PARALLELISM )); then
    wait
    active=0
  fi
done

wait

awk -F'\t' '$2=="PASS"{print $4}' "$REPORT" |
  sort -u > "$PASS_LIST"

PASS_COUNT="$(wc -l < "$PASS_LIST" | tr -d ' ')"

echo
echo "PASS count: $PASS_COUNT"
echo "PASS models:"
cat "$PASS_LIST" || true

if [[ "$PASS_COUNT" -eq 0 ]]; then
  echo "ERROR: Zero models passed. Existing combos will be preserved."
  exit 2
fi

# --------------------------------------------------------
# Model ordering/classification.
#
# This is intentionally based only on health-test results.
# A PASS means the basic OpenAI-compatible smoke test works;
# it does NOT prove tool calling, reasoning quality, context
# length, or production suitability.
# --------------------------------------------------------

sort -t$'\t' -k3,3n "$REPORT" |
  awk -F'\t' '$2=="PASS"{print $3 "\t" $4}' |
  awk -F'\t' '!seen[$2]++' > "$TEST_DIR/passed-by-latency.tsv"

awk -F'\t' '
  {
    m=tolower($2)
    if (
      m ~ /code/ ||
      m ~ /coder/ ||
      m ~ /codestral/ ||
      m ~ /codex/ ||
      m ~ /deepseek/
    ) print $1 "\t" $2
  }
' "$TEST_DIR/passed-by-latency.tsv" > "$TEST_DIR/passed-coding.tsv"

awk -F'\t' '
  {
    m=tolower($2)
    if (
      m ~ /reason/ ||
      m ~ /think/ ||
      m ~ /(^|[^0-9])r1([^0-9]|$)/ ||
      m ~ /(^|[^0-9])o1([^0-9]|$)/ ||
      m ~ /(^|[^0-9])o3([^0-9]|$)/ ||
      m ~ /(^|[^0-9])o4([^0-9]|$)/
    ) print $1 "\t" $2
  }
' "$TEST_DIR/passed-by-latency.tsv" > "$TEST_DIR/passed-reasoning.tsv"

head -n 8 \
  "$TEST_DIR/passed-by-latency.tsv" > "$TEST_DIR/passed-fast.tsv"

head -n 8 \
  "$TEST_DIR/passed-coding.tsv" > "$TEST_DIR/passed-coding-fast.tsv"

# If classification produces an empty pool, fall back to all
# currently healthy models rather than deleting the combo.
[[ -s "$TEST_DIR/passed-coding.tsv" ]] ||
  cp "$TEST_DIR/passed-by-latency.tsv" "$TEST_DIR/passed-coding.tsv"

[[ -s "$TEST_DIR/passed-coding-fast.tsv" ]] ||
  cp "$TEST_DIR/passed-coding.tsv" "$TEST_DIR/passed-coding-fast.tsv"

[[ -s "$TEST_DIR/passed-reasoning.tsv" ]] ||
  cp "$TEST_DIR/passed-by-latency.tsv" "$TEST_DIR/passed-reasoning.tsv"

[[ -s "$TEST_DIR/passed-fast.tsv" ]] ||
  cp "$TEST_DIR/passed-by-latency.tsv" "$TEST_DIR/passed-fast.tsv"

# --------------------------------------------------------
# Combo management.
#
# OmniRoute 3.8.49 supports creating combos via POST and
# editing them via PUT. Do not use PATCH here.
# --------------------------------------------------------

combo_auth=()
if [[ -n "$API_KEY" ]]; then
  combo_auth=(-H "Authorization: Bearer $API_KEY")
fi

COMBOS_JSON="$TEST_DIR/combos.json"

curl \
  --silent \
  --show-error \
  --fail \
  --max-time 15 \
  "${combo_auth[@]}" \
  "$BASE_URL/api/combos" > "$COMBOS_JSON"

get_combo_id() {
  local name="$1"

  jq -r \
    --arg name "$name" \
    '.[]? | select(.name == $name) | .id' \
    "$COMBOS_JSON" |
    head -n 1
}

get_existing_models() {
  local name="$1"

  jq -r \
    --arg name "$name" \
    '.[]?
     | select(.name == $name)
     | (.models // [])
     | .[]
     | (.model // .id // empty)' \
    "$COMBOS_JSON" 2>/dev/null || true
}

model_object() {
  local model="$1"
  local provider="${model%%/*}"

  jq -nc \
    --arg model "$model" \
    --arg provider "$provider" \
    '{
      id: $model,
      kind: "model",
      model: $model,
      providerId: $provider,
      weight: 0
    }'
}

build_models_json() {
  local file="$1"
  local combo_name="$2"
  local tmp_existing="$TEST_DIR/existing-$combo_name.txt"
  local tmp_all="$TEST_DIR/all-$combo_name.txt"

  get_existing_models "$combo_name" |
    while IFS= read -r model; do
      [[ -n "$model" ]] && printf '%s\n' "$model"
    done > "$tmp_existing"

  : > "$tmp_all"

  # Keep existing combo members first, but only when they passed
  # the current health cycle.
  while IFS= read -r model; do
    [[ -z "$model" ]] && continue

    if grep -Fxq "$model" "$PASS_LIST"; then
      printf '%s\n' "$model" >> "$tmp_all"
    fi
  done < "$tmp_existing"

  # Then append the newly healthy profile candidates.
  while IFS=$'\t' read -r latency model; do
    [[ -z "$model" ]] && continue
    printf '%s\n' "$model" >> "$tmp_all"
  done < "$file"

  mapfile -t candidates < <(
    cat "$tmp_all" |
    awk 'NF && !seen[$0]++'
  )

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    # Never replace a healthy combo with an empty model list.
    echo '[]'
    return
  fi

  json='['

  local first=1
  for model in "${candidates[@]}"; do
    if [[ "$first" -eq 0 ]]; then
      json+=','
    fi

    first=0
    json+="$(model_object "$model")"
  done

  json+=']'

  printf '%s\n' "$json"
}

update_or_create_combo() {
  local name="$1"
  local candidate_file="$2"
  local strategy="${3:-priority}"
  local combo_id
  local models_json
  local body
  local response

  combo_id="$(get_combo_id "$name")"
  models_json="$(build_models_json "$candidate_file" "$name")"

  if [[ "$models_json" == "[]" ]]; then
    echo "WARN: $name has no candidate models; preserving existing combo."
    return 0
  fi

  if [[ -n "$combo_id" ]]; then
    # Preserve only server-owned fields that PUT expects.
    body="$(
      jq -nc \
        --arg name "$name" \
        --arg strategy "$strategy" \
        --argjson models "$models_json" \
        '{
          name: $name,
          strategy: $strategy,
          models: $models
        }'
    )"

    response="$(
      curl \
        --silent \
        --show-error \
        --fail \
        --max-time 20 \
        --request PUT \
        "${combo_auth[@]}" \
        -H 'Content-Type: application/json' \
        -d "$body" \
        "$BASE_URL/api/combos/$combo_id"
    )"

    printf '%s\n' "$response" > "$TEST_DIR/combo-response-$name.json"

    echo "UPDATED combo: $name ($combo_id)"
  else
    body="$(
      jq -nc \
        --arg name "$name" \
        --arg strategy "$strategy" \
        --argjson models "$models_json" \
        '{
          name: $name,
          strategy: $strategy,
          models: $models
        }'
    )"

    response="$(
      curl \
        --silent \
        --show-error \
        --fail \
        --max-time 20 \
        --request POST \
        "${combo_auth[@]}" \
        -H 'Content-Type: application/json' \
        -d "$body" \
        "$BASE_URL/api/combos"
    )"

    printf '%s\n' "$response" > "$TEST_DIR/combo-response-$name.json"

    echo "CREATED combo: $name"
  fi

  {
    echo "[$name]"
    echo "$models_json" | jq -r '.[].model'
    echo
  } >> "$COMBO_REPORT"
}

: > "$COMBO_REPORT"

update_or_create_combo \
  "coding" \
  "$TEST_DIR/passed-coding.tsv" \
  "priority"

update_or_create_combo \
  "coding-fast" \
  "$TEST_DIR/passed-coding-fast.tsv" \
  "priority"

update_or_create_combo \
  "reasoning" \
  "$TEST_DIR/passed-reasoning.tsv" \
  "priority"

update_or_create_combo \
  "fast" \
  "$TEST_DIR/passed-fast.tsv" \
  "priority"

echo
echo "============================================================"
echo "UPDATED COMBOS"
echo "============================================================"

cat "$COMBO_REPORT"

# Keep a stable latest report for SSH/manual inspection.
cp "$REPORT" "$TEST_DIR/latest-models.tsv"
cp "$PASS_LIST" "$TEST_DIR/pass-models.txt"
cp "$COMBO_REPORT" "$TEST_DIR/latest-combos.txt"

# Retain only the latest 48 cycles (~24 hours at 30-min cadence).
find "$HISTORY_DIR" -type f -printf '%T@ %p\n' |
  sort -nr |
  awk 'NR>96{print $2}' |
  xargs -r rm -f

echo "Model health/combo synchronization completed."

