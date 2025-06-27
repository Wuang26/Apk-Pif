#!/system/bin/sh

# Toybox
date(){ /system/bin/date "$@"; }

FORCE_DEPTH=1

# Fetch Pixel Beta page
wget -q -O PIXEL_VERSIONS_HTML --no-check-certificate https://developer.android.com/about/versions || exit 1
wget -q -O PIXEL_LATEST_HTML --no-check-certificate "$(grep -o 'https://developer.android.com/about/versions/.*[0-9]"' PIXEL_VERSIONS_HTML | head -n1 | cut -d\" -f1)" || exit 1

if grep -qE 'Developer Preview|tooltip>.*preview program' PIXEL_LATEST_HTML && [ ! "$FORCE_PREVIEW" ]; then
  wget -q -O PIXEL_BETA_HTML --no-check-certificate "$(grep -o 'https://developer.android.com/about/versions/.*[0-9]"' PIXEL_VERSIONS_HTML | head -n2 | tail -n1 | cut -d\" -f1)" || exit 1
else
  TITLE="Preview"
  mv -f PIXEL_LATEST_HTML PIXEL_BETA_HTML
fi

wget -q -O PIXEL_OTA_HTML --no-check-certificate "https://developer.android.com$(grep -o 'href=".*download-ota.*"' PIXEL_BETA_HTML | cut -d\" -f2 | head -n$FORCE_DEPTH | tail -n1)" || exit 1

echo "$(grep -m1 -oE 'tooltip>Android .*[0-9]' PIXEL_OTA_HTML | cut -d\> -f2) $TITLE$(grep -oE 'tooltip>QPR.* Beta' PIXEL_OTA_HTML | cut -d\> -f2 | head -n$FORCE_DEPTH | tail -n1)"

# Parse release date using grep + sed POSIX (avoid \1 references)
BETA_REL_DATE="$(grep -m1 -A1 'Release date' PIXEL_OTA_HTML | tail -n1 | sed -E 's/.*<td>(.*)<\/td>.*/\1/')"
BETA_EXP_DATE="$(date -d "$BETA_REL_DATE +42 days" '+%Y-%m-%d' 2>/dev/null || echo "")"

echo -e "Beta Released: $BETA_REL_DATE\nEstimated Expiry: $BETA_EXP_DATE"

MODEL_LIST="$(grep -A1 'tr id=' PIXEL_OTA_HTML | grep 'td' | sed -E 's/.*<td>(.*)<\/td>.*/\1/')"
PRODUCT_LIST="$(grep -o 'ota/.*_beta' PIXEL_OTA_HTML | cut -d\/ -f2)"
OTA_LIST="$(grep 'ota/.*_beta' PIXEL_OTA_HTML | cut -d\" -f2)"

# Random select if PRODUCT unset
if [ -z "$PRODUCT" ]; then
  set_random_beta() {
    local list_count="$(echo "$MODEL_LIST" | wc -l)"
    local list_rand="$((RANDOM % list_count + 1))"
    local IFS=$'\n'
    set -- $MODEL_LIST; MODEL="$(eval echo \${$list_rand})"
    set -- $PRODUCT_LIST; PRODUCT="$(eval echo \${$list_rand})"
    set -- $OTA_LIST; OTA="$(eval echo \${$list_rand})"
    DEVICE="$(echo "$PRODUCT" | sed 's/_beta//')"
  }
  set_random_beta
fi
echo "$MODEL ($PRODUCT)"

# Download OTA metadata
curl -s -L -k "$OTA" | head -c 8048 > PIXEL_ZIP_METADATA || exit 1

FINGERPRINT="$(grep -am1 'post-build=' PIXEL_ZIP_METADATA | cut -d= -f2)"
SECURITY_PATCH="$(grep -am1 'security-patch-level=' PIXEL_ZIP_METADATA | cut -d= -f2)"
[ -z "$FINGERPRINT" ] && { echo "Error: Failed to extract fingerprint!"; exit 1; }

# Build test.json
cat <<EOF | tee test.json
{
  "com.google.android.gms": {
    "FINGERPRINT": "$FINGERPRINT",
    "MANUFACTURER": "Google",
    "BRAND": "google",
    "MODEL": "$MODEL",
    "PRODUCT": "$PRODUCT",
    "DEVICE": "$DEVICE",
    "BOARD": "$DEVICE",
    "SECURITY_PATCH": "$SECURITY_PATCH"
  }
}
EOF

# Fetch PIF.json metadata
wget -q -O PIF_METADATA --no-check-certificate https://github.com/Zenlua/Tool-Tree/releases/download/V1/PIF.json || curl -s -L -k -o PIF_METADATA https://github.com/Zenlua/Tool-Tree/releases/download/V1/PIF.json || { echo "Lỗi tải PIF"; exit 1; }

# Process spoof_config
if grep -q spoof_config PIF_METADATA; then
  [ "$LIT" ] && jq '. + { "spoof_config": "'"$LIT"'" }' PIF_METADATA > tmp && mv tmp PIF_METADATA
  [ "$LUN" ] && jq '. + { "shell": "'"$LUN"'" }' PIF_METADATA > tmp && mv tmp PIF_METADATA

  jq -r .spoof_config PIF_METADATA | base64 -d > metaindex_decoded.json
  jq '. + '"$(cat test.json)"'' metaindex_decoded.json > devices.json

  # Encode back
  cat devices.json | base64 -w0 > metaindex
  jq '. + { "spoof_config": "'"$(cat metaindex)"'" }' PIF_METADATA > PIF.json

  # Generate pif.prop
  echo "pif=0" > pif.prop
  index=1

  for key in $(jq -r 'keys[]' devices.json); do
    FINGERPRINT="$(jq -r --arg k "$key" '.[$k].FINGERPRINT' devices.json)"
    [ -z "$FINGERPRINT" ] && continue

    PRODUCT="$(jq -r --arg k "$key" '.[$k].PRODUCT' devices.json)"
    DEVICE="$(jq -r --arg k "$key" '.[$k].DEVICE' devices.json)"
    SECURITY_PATCH="$(jq -r --arg k "$key" '.[$k].SECURITY_PATCH' devices.json)"

    # codename mapping
    case "$DEVICE" in
      oriole) MODEL="Pixel 6";;
      raven) MODEL="Pixel 6 Pro";;
      bluejay) MODEL="Pixel 6a";;
      panther) MODEL="Pixel 7";;
      cheetah) MODEL="Pixel 7 Pro";;
      lynx) MODEL="Pixel 7a";;
      shiba) MODEL="Pixel 8";;
      husky) MODEL="Pixel 8 Pro";;
      akita) MODEL="Pixel 8a";;
      komodo) MODEL="Pixel 9 Pro XL";;
      tokay) MODEL="Pixel 9 Pro";;
      tegu) MODEL="Pixel 9a";;
      *) MODEL="Unknown";;
    esac

    # Parse other fields
    RELEASE="$(echo "$FINGERPRINT" | cut -d: -f2 | cut -d/ -f1)"
    ID="$(echo "$FINGERPRINT" | cut -d/ -f4)"
    INCREMENTAL="$(echo "$FINGERPRINT" | cut -d/ -f5 | cut -d: -f1)"
    TYPE="$(echo "$FINGERPRINT" | cut -d: -f3 | cut -d/ -f1)"
    TAGS="$(echo "$FINGERPRINT" | cut -d: -f3 | cut -d/ -f2)"

    {
      echo
      echo "Pif_$index={"
      echo "BRAND=google"
      echo "DEVICE=$DEVICE"
      echo "DEVICE_INITIAL_SDK_INT=25"
      echo "FINGERPRINT=$FINGERPRINT"
      echo "ID=$ID"
      echo "MANUFACTURER=Google"
      echo "MODEL=$MODEL"
      echo "PRODUCT=$PRODUCT"
      echo "RELEASE=$RELEASE"
      echo "INCREMENTAL=$INCREMENTAL"
      echo "SECURITY_PATCH=$SECURITY_PATCH"
      echo "TAGS=$TAGS"
      echo "TYPE=$TYPE"
      echo "}"
    } >> pif.prop

    index=$((index + 1))
  done

  sed -i "1s/.*/pif=$((index - 1))/" pif.prop
  echo -e "\n✅ Đã tạo pif.prop với $((index - 1)) profiles."

  # Cleanup
  rm -f PIXEL_VERSIONS_HTML PIXEL_LATEST_HTML PIXEL_BETA_HTML PIXEL_OTA_HTML PIXEL_ZIP_METADATA test.json PIF_METADATA metaindex metaindex_decoded.json devices.json tmp

  exit 0

else
  echo "Lỗi: spoof_config không tồn tại trong PIF_METADATA."
  exit 1
fi