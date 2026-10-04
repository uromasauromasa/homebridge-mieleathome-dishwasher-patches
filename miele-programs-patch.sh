#!/bin/bash
# homebridge-mieleathome v3.5.0 用パッチ（miele-autostart-patch.sh を当てたあとに使う）
# 食洗機に「プログラムごとのスイッチ」を追加する。
# スイッチをオンにすると「電源オン → そのプログラムで開始」し、スイッチは数秒で自動的にオフに戻る。
#
# 使い方（Raspberry Pi 上で）:
#   sudo bash miele-programs-patch.sh          パッチを当てる
#   sudo bash miele-programs-patch.sh restore  元に戻す
#
# スイッチの種類は Homebridge の設定（config.json の Miele@home の項目）で変えられます:
#   "dishwasherPrograms": [
#     { "name": "エコ", "programId": 3 },
#     { "name": "オート", "programId": 7 },
#     { "name": "スピード", "programId": 13 }
#   ]
# 省略時は上の3つになります。

set -e

DIR="$(npm root -g 2>/dev/null)/homebridge-mieleathome/dist"
[ -f "$DIR/platform.js" ] || DIR="/usr/local/lib/node_modules/homebridge-mieleathome/dist"
[ -f "$DIR/platform.js" ] || DIR="/var/lib/homebridge/node_modules/homebridge-mieleathome/dist"
C="$DIR/mieleCharacteristics.js"
A="$DIR/mieleWasherDryerPlatformAccessory.js"
P="$DIR/platform.js"

if [ ! -f "$P" ]; then
  echo "エラー: homebridge-mieleathome が見つかりません。"
  exit 1
fi
echo "対象フォルダ: $DIR"

if [ "$1" = "restore" ]; then
  for f in "$C" "$A" "$P"; do
    if [ -f "$f.before-programs" ]; then
      cp "$f.before-programs" "$f"
      echo "元に戻しました: $f"
    fi
  done
  echo "Homebridge を再起動してください: sudo hb-service restart"
  exit 0
fi

if ! grep -q "PATCHED-MIELE-AUTOSTART" "$C"; then
  echo "エラー: 先に miele-autostart-patch.sh を当ててください。"
  exit 1
fi
if grep -q "PATCHED-MIELE-PROGRAMS" "$A"; then
  echo "すでにパッチ済みです。何もしません。"
  exit 0
fi

for f in "$C" "$A" "$P"; do cp "$f" "$f.before-programs"; done
echo "バックアップを作成しました（*.before-programs）"

python3 - "$C" "$A" "$P" <<'PYEOF'
import sys
C, A, P = sys.argv[1:4]

def patch(path, reps):
    s = open(path, encoding='utf-8').read()
    for old, new in reps:
        if s.count(old) != 1:
            print("エラー: 想定と違うコードです:", path)
            print(old)
            sys.exit(1)
        s = s.replace(old, new)
    return s

# 1. 開始処理にプログラム番号を渡せるようにする
c = patch(C, [
 ("MieleWritableBinaryStateCharacteristic.prototype.patchedAutoStart = async function (actions) {",
  "MieleWritableBinaryStateCharacteristic.prototype.patchedAutoStart = async function (actions, programIdOverride) {  // PATCHED-MIELE-PROGRAMS"),
 ("const programId = Number(this.platform.config.dishwasherProgramId) || 7;",
  "const programId = Number(programIdOverride) || Number(this.platform.config.dishwasherProgramId) || 7;"),
])

# 2. 機器の種類を覚えておく（食洗機だけにスイッチを付けるため）
p = patch(P, [
 ("    constructPlatformAccessory(raw_id, accessory) {",
  "    constructPlatformAccessory(raw_id, accessory) {\n        accessory.context.patchedType = raw_id;  // PATCHED-MIELE-PROGRAMS"),
])

# 3. 食洗機にプログラムごとのスイッチを追加する
a = patch(A, [
 ("        // Temperature sensor service\n",
  """        // PATCHED-MIELE-PROGRAMS: one switch per dishwasher program
        this.patchedSetupProgramSwitches(accessory);
        // Temperature sensor service
"""),
 ("exports.MieleWasherDryerPlatformAccessory = MieleWasherDryerPlatformAccessory;",
  """MieleWasherDryerPlatformAccessory.prototype.patchedSetupProgramSwitches = function (accessory) {
    const platform = this.platform;
    const Switch = platform.Service.Switch;
    const isDishwasher = accessory.context.patchedType === 7;
    let programs = platform.config.dishwasherPrograms;
    if (!Array.isArray(programs) || programs.length === 0) {
        programs = [
            { name: 'エコ', programId: 3 },
            { name: 'オート', programId: 7 },
            { name: 'スピード', programId: 13 },
        ];
    }
    const wanted = isDishwasher ? programs.map((p) => 'prog-' + p.programId) : [];
    // Remove switches that are no longer configured.
    for (const svc of accessory.services.slice()) {
        if (svc.UUID === Switch.UUID && svc.subtype && svc.subtype.startsWith('prog-') && !wanted.includes(svc.subtype)) {
            accessory.removeService(svc);
        }
    }
    if (!isDishwasher) {
        return;
    }
    const serial = accessory.context.device.uniqueId;
    const baseName = accessory.context.device.displayName;
    const ctx = { platform: platform, serialNumber: serial, deviceName: baseName };
    const autoStart = mieleCharacteristics_1.MieleWritableBinaryStateCharacteristic.prototype.patchedAutoStart;
    const axios = require('axios').default;
    for (const prog of programs) {
        const subtype = 'prog-' + prog.programId;
        const label = `${baseName} ${prog.name}`;
        const svc = accessory.getServiceById(Switch, subtype) || accessory.addService(Switch, label, subtype);
        svc.setCharacteristic(platform.Characteristic.Name, label);
        svc.getCharacteristic(platform.Characteristic.On)
            .on('get', (callback) => callback(null, false))
            .on('set', async (value, callback) => {
            callback(null);
            if (!value) {
                return;
            }
            try {
                platform.log.info(`${baseName}: Program switch "${prog.name}" (${prog.programId}) turned on.`);
                const actions = (await axios.get(platform.getActionsUrl(serial), platform.getHttpRequestConfig())).data;
                await autoStart.call(ctx, actions, prog.programId);
            }
            catch (e) {
                platform.log.error(`${baseName}: Program switch failed: ${e}`);
            }
            setTimeout(() => svc.updateCharacteristic(platform.Characteristic.On, false), 3000);
        });
    }
};
exports.MieleWasherDryerPlatformAccessory = MieleWasherDryerPlatformAccessory;"""),
])

open(C, 'w', encoding='utf-8').write(c)
open(P, 'w', encoding='utf-8').write(p)
open(A, 'w', encoding='utf-8').write(a)
print("パッチを当てました。")
PYEOF

node --check "$C" && node --check "$A" && node --check "$P" && echo "構文チェック OK"
echo "Homebridge を再起動してください: sudo hb-service restart"
