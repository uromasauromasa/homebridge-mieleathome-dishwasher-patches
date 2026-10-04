#!/bin/bash
# homebridge-mieleathome v3.5.0 用パッチ
# 食洗機（洗濯機・乾燥機も同じ）をスプリンクラー型のバルブにして、
# ホームアプリに残り時間を表示させる
#
# 使い方（Raspberry Pi 上で）:
#   sudo bash miele-duration-patch.sh          パッチを当てる
#   sudo bash miele-duration-patch.sh restore  元に戻す

set -e

DIR="$(npm root -g 2>/dev/null)/homebridge-mieleathome/dist"
[ -f "$DIR/mieleWasherDryerPlatformAccessory.js" ] || DIR="/usr/local/lib/node_modules/homebridge-mieleathome/dist"
[ -f "$DIR/mieleWasherDryerPlatformAccessory.js" ] || DIR="/var/lib/homebridge/node_modules/homebridge-mieleathome/dist"
F="$DIR/mieleWasherDryerPlatformAccessory.js"

if [ ! -f "$F" ]; then
  echo "エラー: homebridge-mieleathome が見つかりません。"
  exit 1
fi
echo "対象: $F"

if [ "$1" = "restore" ]; then
  if [ -f "$F.orig" ]; then
    cp "$F.orig" "$F"
    echo "元に戻しました。Homebridge を再起動してください: sudo hb-service restart"
  else
    echo "バックアップ ($F.orig) がありません。"
  fi
  exit 0
fi

if grep -q "PATCHED-MIELE-DURATION" "$F"; then
  echo "すでにパッチ済みです。何もしません。"
  exit 0
fi

cp "$F" "$F.orig"
echo "バックアップを作成しました: $F.orig"

python3 - "$F" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

reps = [
# (1) 蛇口 → スプリンクラー型（ホームアプリが残り時間を表示する種類）
("this.platform.Characteristic.ValveType.WATER_FAUCET);",
 "this.platform.Characteristic.ValveType.IRRIGATION);  // PATCHED-MIELE-DURATION"),

# (2) タイマー（SetDuration）の欄を追加。値は残り時間と同じものを返し、変更は無視する
("""            .setProps({
            minValue: 0,
            maxValue: this.MAX_REMAINING_DURATION,
            minStep: 1,
        });
""",
 """            .setProps({
            minValue: 0,
            maxValue: this.MAX_REMAINING_DURATION,
            minStep: 1,
        });
        // PATCHED-MIELE-DURATION: SetDuration so that the Home app shows the remaining time
        this.mainService.getCharacteristic(this.platform.Characteristic.SetDuration)
            .setProps({
            minValue: 0,
            maxValue: this.MAX_REMAINING_DURATION,
            minStep: 1,
        })
            .on('get', (callback) => {
            callback(null, this.mainService.getCharacteristic(this.platform.Characteristic.RemainingDuration).value || 0);
        })
            .on('set', (value, callback) => {
            callback();  // program duration is decided by the appliance
        });
"""),
]

for old, new in reps:
    if s.count(old) != 1:
        print("エラー: 想定と違うコードです。ファイルは変更していません。")
        sys.exit(1)
    s = s.replace(old, new)

open(p, 'w', encoding='utf-8').write(s)
print("パッチを当てました。")
PYEOF

node --check "$F" && echo "構文チェック OK"
echo "Homebridge を再起動してください: sudo hb-service restart"
