#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

base_url=""
pdf_file=""
ocr_file=""
office_file=""
restart_test=false
public_ip=""
pass_count=0
fail_count=0
skip_count=0
temporary_files=()

usage() {
  cat >&2 <<'EOF'
usage: smoke-test.sh [options]
  --url URL             Tailscale HTTPS origin
  --pdf FILE            Real PDF for MCP upload, rotate, and download
  --ocr-pdf FILE        Scanned Norwegian/English PDF for OCR validation
  --office-file FILE    Office document for LibreOffice conversion
  --public-ip IP        Public address expected to reject ports 8080 and 443
  --restart-test        Restart the container and re-check persistence

The script reads MCP_API_KEY from the environment or prompts without echo.
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) base_url="${2:-}"; shift 2 ;;
    --pdf) pdf_file="${2:-}"; shift 2 ;;
    --ocr-pdf) ocr_file="${2:-}"; shift 2 ;;
    --office-file) office_file="${2:-}"; shift 2 ;;
    --public-ip) public_ip="${2:-}"; shift 2 ;;
    --restart-test) restart_test=true; shift ;;
    *) usage ;;
  esac
done

if [ -z "$base_url" ] && [ -r /opt/stirling-pdf/.env ]; then
  base_url="$(sed -n 's/^STIRLING_PUBLIC_URL=//p' /opt/stirling-pdf/.env | tail -1)"
fi
[[ "$base_url" =~ ^https:// ]] || usage
base_url="${base_url%/}"

if [ -z "${MCP_API_KEY:-}" ]; then
  read -r -s -p "MCP user's API key: " MCP_API_KEY
  echo
fi
[ -n "$MCP_API_KEY" ] || {
  echo "an MCP API key is required" >&2
  exit 2
}

cleanup() {
  if [ "${#temporary_files[@]}" -gt 0 ]; then
    rm -f "${temporary_files[@]}"
  fi
}
trap cleanup EXIT

pass() {
  printf 'PASS: %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  fail_count=$((fail_count + 1))
}

skip() {
  printf 'SKIP: %s\n' "$1"
  skip_count=$((skip_count + 1))
}

rpc() {
  curl -fsS --connect-timeout 10 --max-time 600 \
    -H 'Content-Type: application/json' \
    -H "X-API-KEY: ${MCP_API_KEY}" \
    --data-binary "$1" "${base_url}/mcp"
}

extract_file_id() {
  jq -r '
    [.result.content[]?.text? | try capture("fileId=(?<id>[A-Za-z0-9_-]+)").id catch empty]
    | first // empty
  '
}

upload_file() {
  local path="$1" encoded request response file_id
  encoded="$(base64 -w0 "$path")"
  request="$(jq -cn --arg file "$encoded" --arg name "$(basename "$path")" \
    '{jsonrpc:"2.0",id:20,method:"tools/call",params:{name:"stirling_upload",arguments:{file:$file,fileName:$name}}}')"
  response="$(rpc "$request")"
  file_id="$(printf '%s' "$response" | extract_file_id)"
  [ -n "$file_id" ] || {
    printf 'upload failed: %s\n' "$(printf '%s' "$response" | head -c 300)" >&2
    return 1
  }
  printf '%s' "$file_id"
}

call_operation() {
  local tool="$1" operation="$2" file_id="$3" file_name="$4" parameters="$5" request
  request="$(jq -cn \
    --arg tool "$tool" \
    --arg operation "$operation" \
    --arg file_id "$file_id" \
    --arg file_name "$file_name" \
    --argjson parameters "$parameters" \
    '{jsonrpc:"2.0",id:21,method:"tools/call",params:{name:$tool,arguments:{operation:$operation,fileId:$file_id,fileName:$file_name,parameters:$parameters}}}')"
  rpc "$request"
}

download_file() {
  local file_id="$1" destination="$2" request response blob
  request="$(jq -cn --arg file_id "$file_id" \
    '{jsonrpc:"2.0",id:22,method:"tools/call",params:{name:"stirling_download",arguments:{fileId:$file_id}}}')"
  response="$(rpc "$request")"
  blob="$(printf '%s' "$response" | jq -r \
    '.result.content[]? | select(.type == "resource") | .resource.blob' | head -1)"
  [ -n "$blob" ] && [ "$blob" != "null" ] || return 1
  printf '%s' "$blob" | base64 --decode >"$destination"
}

status_body="$(curl -fsS --connect-timeout 10 --max-time 30 "${base_url}/api/v1/info/status" || true)"
if printf '%s' "$status_body" | grep -q 'UP'; then
  pass "status endpoint reports UP"
else
  fail "status endpoint did not report UP"
fi

ui_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 "$base_url" || true)"
case "$ui_code" in
  200 | 302) pass "UI responds over Tailscale HTTPS" ;;
  *) fail "UI returned HTTP ${ui_code:-none}" ;;
esac

no_key_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 \
  -H 'Content-Type: application/json' \
  --data-binary '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "${base_url}/mcp" || true)"
if [ "$no_key_code" = "401" ]; then
  pass "MCP without a key returns 401"
else
  fail "MCP without a key returned ${no_key_code:-none}"
fi

initialize="$(rpc '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"production-smoke","version":"1"}}}' || true)"
if [ "$(printf '%s' "$initialize" | jq -r '.result.protocolVersion // empty')" = "2025-06-18" ]; then
  pass "MCP initialize negotiated streamable HTTP protocol"
else
  fail "MCP initialize failed"
fi

tools="$(rpc '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' || true)"
if printf '%s' "$tools" | jq -e \
  '[.result.tools[]?.name] |
    (index("stirling_upload") != null) and
    (index("stirling_download") != null) and
    (index("stirling_pages") != null) and
    (index("stirling_misc") != null) and
    (index("stirling_convert") != null)' \
  >/dev/null; then
  pass "MCP tools/list includes upload, download, pages, misc, and convert"
else
  fail "MCP tools/list is incomplete"
fi

if docker exec stirling-pdf tesseract --list-langs 2>/dev/null |
  grep -qx 'eng' &&
  docker exec stirling-pdf tesseract --list-langs 2>/dev/null |
    grep -qx 'nor'; then
  pass "container detects English and Norwegian OCR data"
else
  fail "container does not detect both eng and nor OCR data"
fi

if docker exec stirling-pdf soffice --version >/dev/null 2>&1; then
  pass "LibreOffice is installed in the fat image"
else
  fail "LibreOffice is unavailable"
fi

if [ -n "$pdf_file" ]; then
  if input_id="$(upload_file "$pdf_file")"; then
    pass "real PDF uploaded and returned fileId"
    rotate_response="$(call_operation stirling_pages rotate-pdf "$input_id" \
      "$(basename "$pdf_file")" '{"angle":90}' || true)"
    rotated_id="$(printf '%s' "$rotate_response" | extract_file_id)"
    if [ -n "$rotated_id" ]; then
      pass "rotate-pdf returned a chained fileId"
      rotated_output="$(mktemp --suffix=.pdf)"
      temporary_files+=("$rotated_output")
      if download_file "$rotated_id" "$rotated_output" &&
        head -c 5 "$rotated_output" | grep -q '%PDF'; then
        pass "rotated result downloaded as a PDF"
      else
        fail "rotated result could not be downloaded"
      fi
    else
      fail "rotate-pdf did not return fileId"
    fi
  else
    fail "real PDF upload failed"
  fi
else
  skip "provide --pdf to test upload, rotation, fileId chaining, and download"
fi

if [ -n "$ocr_file" ]; then
  if ocr_input_id="$(upload_file "$ocr_file")"; then
    ocr_response="$(call_operation stirling_misc ocr-pdf "$ocr_input_id" "$(basename "$ocr_file")" \
      '{"languages":["nor","eng"],"deskew":true,"sidecar":false,"clean":false,"cleanFinal":false,"ocrType":"Normal","ocrRenderType":"hocr","removeImagesAfter":false}' || true)"
    ocr_output_id="$(printf '%s' "$ocr_response" | extract_file_id)"
    ocr_output="$(mktemp --suffix=.pdf)"
    temporary_files+=("$ocr_output")
    if [ -n "$ocr_output_id" ] && download_file "$ocr_output_id" "$ocr_output" &&
      docker exec -i stirling-pdf pdftotext - - <"$ocr_output" 2>/dev/null |
        grep -q '[[:alnum:]]'; then
      pass "Norwegian/English OCR produced searchable text with deskew"
    else
      fail "OCR did not produce searchable text"
    fi
  else
    fail "OCR sample upload failed"
  fi
else
  skip "provide --ocr-pdf with a scanned bilingual sample to test OCR"
fi

if [ -n "$office_file" ]; then
  office_output="$(mktemp --suffix=.pdf)"
  temporary_files+=("$office_output")
  office_code="$(curl -sS -o "$office_output" -w '%{http_code}' \
    --connect-timeout 10 --max-time 600 \
    -H "X-API-KEY: ${MCP_API_KEY}" \
    -F "fileInput=@${office_file}" \
    "${base_url}/api/v1/convert/file/pdf" || true)"
  if [ "$office_code" = "200" ] &&
    head -c 5 "$office_output" | grep -q '%PDF'; then
    pass "LibreOffice REST conversion produced a PDF"
  else
    fail "LibreOffice REST conversion failed (HTTP ${office_code:-none})"
  fi
else
  skip "provide --office-file to test LibreOffice conversion"
fi

if ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)0\.0\.0\.0:8080$|^\*:8080$|^\[::\]:8080$'; then
  fail "port 8080 is listening on a public wildcard"
else
  pass "port 8080 is not bound to a public wildcard"
fi

if [ -n "$public_ip" ]; then
  if curl -fsS --connect-timeout 5 --max-time 10 "http://${public_ip}:8080" >/dev/null 2>&1 ||
    curl -fkSs --connect-timeout 5 --max-time 10 "https://${public_ip}" >/dev/null 2>&1; then
    fail "public IP reached Stirling on 8080 or 443"
  else
    pass "public IP did not reach Stirling on 8080 or 443"
  fi
else
  skip "verify the public IP externally or provide --public-ip"
fi

if "$restart_test"; then
  settings_before="$(sha256sum /srv/stirling-pdf/config/settings.yml | cut -d' ' -f1)"
  pipeline_before="$(find /srv/stirling-pdf/pipeline -type f -print0 |
    sort -z | xargs -0r sha256sum | sha256sum | cut -d' ' -f1)"
  docker restart stirling-pdf >/dev/null
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' stirling-pdf 2>/dev/null)" = "healthy" ] && break
    sleep 5
  done
  settings_after="$(sha256sum /srv/stirling-pdf/config/settings.yml | cut -d' ' -f1)"
  pipeline_after="$(find /srv/stirling-pdf/pipeline -type f -print0 |
    sort -z | xargs -0r sha256sum | sha256sum | cut -d' ' -f1)"
  if [ "$settings_before" = "$settings_after" ] &&
    [ "$pipeline_before" = "$pipeline_after" ] &&
    [ "$(docker inspect -f '{{.State.Health.Status}}' stirling-pdf)" = "healthy" ]; then
    pass "restart preserved settings and pipelines"
  else
    fail "restart persistence check failed"
  fi
else
  skip "use --restart-test after exporting production pipelines"
fi

printf '\nSummary: %d passed, %d failed, %d skipped\n' \
  "$pass_count" "$fail_count" "$skip_count"
[ "$fail_count" -eq 0 ]
