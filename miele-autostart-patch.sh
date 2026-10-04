#!/bin/bash
# homebridge-mieleathome v3.5.0 用パッチ
# ホームアプリで食洗機をオンにしたとき「電源オン → プログラム選択 → 開始」を行う
#
# 使い方（Raspberry Pi 上で）:
#   sudo bash miele-autostart-patch.sh          パッチを当てる
#   sudo bash miele-autostart-patch.sh restore  元に戻す
#
# 使うプログラムは Homebridge の設定（config.json の Miele@home の項目）に
#   "dishwasherProgramId": 3
# のように書くと変えられます（省略時は 7 = Auto）。
# 本体の設定で MobileStart がオフのときは何もしません。

set -e

DIR="$(npm root -g 2>/dev/null)/homebridge-mieleathome/dist"
[ -f "$DIR/mieleCharacteristics.js" ] || DIR="/usr/local/lib/node_modules/homebridge-mieleathome/dist"
[ -f "$DIR/mieleCharacteristics.js" ] || DIR="/var/lib/homebridge/node_modules/homebridge-mieleathome/dist"
F="$DIR/mieleCharacteristics.js"

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

if grep -q "PATCHED-MIELE-AUTOSTART" "$F"; then
  echo "すでにパッチ済みです。何もしません。"
  exit 0
fi

cp "$F" "$F.orig"
echo "バックアップを作成しました: $F.orig"

python3 - "$F" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

old_if = """            // If allowed to execute action.
            if (response.data.processAction.includes(mieleProcesAction)) {"""
new_if = """            // PATCHED-MIELE-AUTOSTART: dishwasher power on + program start
            if (mieleProcesAction === MieleProcessAction.Start &&
                !response.data.processAction.includes(mieleProcesAction) &&
                await this.patchedAutoStart(response.data)) {
                return;
            }
            // If allowed to execute action.
            if (response.data.processAction.includes(mieleProcesAction)) {"""

old_cls = """exports.MieleWritableBinaryStateCharacteristic = MieleWritableBinaryStateCharacteristic;"""
new_cls = """// PATCHED-MIELE-AUTOSTART
MieleWritableBinaryStateCharacteristic.prototype.patchedAutoStart = async function (actions) {
    const cfg = this.platform.getHttpRequestConfig();
    const actionsUrl = this.platform.getActionsUrl(this.serialNumber);
    const devUrl = actionsUrl.replace(/\\/actions$/, '');
    const name = `${this.deviceName} (${this.serialNumber})`;
    try {
        let dev = (await axios_1.default.get(devUrl + '?language=en', cfg)).data;
        if (!dev || !dev.ident || !dev.ident.type || dev.ident.type.value_raw !== 7) {
            return false;  // dishwasher only
        }
        if (!dev.state || !dev.state.remoteEnable || !dev.state.remoteEnable.mobileStart) {
            this.platform.log.info(`${name}: MobileStart is off on the appliance. Not starting.`);
            return false;
        }
        if (dev.state.status.value_raw === 1) {  // Off
            if (!actions.powerOn) {
                this.platform.log.info(`${name}: Power on not allowed in current state.`);
                return false;
            }
            this.platform.log.info(`${name}: Powering on.`);
            try {
                await axios_1.default.put(actionsUrl, { powerOn: true }, cfg);
            }
            catch (e) {
                // Miele often answers 500 although the appliance powers on.
                this.platform.log.debug(`${name}: Power on returned an error (ignored): ${e}`);
            }
            for (let i = 0; i < 15; i++) {
                await new Promise((r) => setTimeout(r, 2000));
                dev = (await axios_1.default.get(devUrl + '?language=en', cfg)).data;
                if (dev.state.status.value_raw !== 1) {
                    break;
                }
            }
            if (dev.state.status.value_raw === 1) {
                this.platform.log.info(`${name}: Appliance did not power on.`);
                return false;
            }
        }
        const programId = Number(this.platform.config.dishwasherProgramId) || 7;
        this.platform.log.info(`${name}: Starting program ${programId}.`);
        await axios_1.default.put(devUrl + '/programs', { programId: programId }, cfg);
        return true;
    }
    catch (e) {
        this.platform.log.error(`${name}: Auto start failed: ${platform_1.createErrorString(e)}`);
        return false;
    }
};
exports.MieleWritableBinaryStateCharacteristic = MieleWritableBinaryStateCharacteristic;"""

for old, new in [(old_if, new_if), (old_cls, new_cls)]:
    if s.count(old) != 1:
        print("エラー: 想定と違うコードです。ファイルは変更していません。")
        sys.exit(1)
    s = s.replace(old, new)

open(p, 'w', encoding='utf-8').write(s)
print("パッチを当てました。")
PYEOF

node --check "$F" && echo "構文チェック OK"
echo "Homebridge を再起動してください: sudo hb-service restart"
