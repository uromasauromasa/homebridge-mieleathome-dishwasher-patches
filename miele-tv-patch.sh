#!/bin/bash
# homebridge-mieleathome v3.5.0 用パッチ（miele-autostart-patch.sh を当てたあとに使う）
# 食洗機を「テレビ型」の機器としても公開する。
#   電源ボタン       → 食洗機の電源を入れる（洗浄はまだ始めない）
#   入力切り替え一覧 → 選んだプログラムで洗浄を開始する
#   電源ボタンでオフ → 洗浄中なら停止、そうでなければ電源を切る
#
# 使い方（Raspberry Pi 上で）:
#   sudo bash miele-tv-patch.sh          パッチを当てる
#   sudo bash miele-tv-patch.sh restore  元に戻す
#
# 設定（config.json の Miele@home の項目、すべて省略可）:
#   "dishwasherPrograms": [ { "name": "エコ", "programId": 3 }, ... ]   一覧に出すプログラム
#   "dishwasherTvName": "食洗機"                                        テレビ型の名前
#   "dishwasherTvDisableStop": true                                     洗浄中に電源ボタンで止めない
#   "dishwasherTvExternal": false                                       独立した機器でなくブリッジ経由で登録する

set -e

DIR="$(npm root -g 2>/dev/null)/homebridge-mieleathome/dist"
[ -f "$DIR/platform.js" ] || DIR="/usr/local/lib/node_modules/homebridge-mieleathome/dist"
[ -f "$DIR/platform.js" ] || DIR="/var/lib/homebridge/node_modules/homebridge-mieleathome/dist"
P="$DIR/platform.js"
C="$DIR/mieleCharacteristics.js"
T="$DIR/patchedDishwasherTv.js"

if [ ! -f "$P" ]; then
  echo "エラー: homebridge-mieleathome が見つかりません。"
  exit 1
fi
echo "対象フォルダ: $DIR"

if [ "$1" = "restore" ]; then
  if [ -f "$P.before-tv" ]; then
    cp "$P.before-tv" "$P"
    if grep -q "PATCHED-MIELE-TV" "$C" && [ -f "$C.before-tv" ]; then cp "$C.before-tv" "$C"; fi
    rm -f "$T"
    echo "元に戻しました。Homebridge を再起動してください: sudo hb-service restart"
  else
    echo "バックアップ ($P.before-tv) がありません。"
  fi
  exit 0
fi

if ! grep -q "PATCHED-MIELE-AUTOSTART" "$C"; then
  echo "エラー: 先に miele-autostart-patch.sh を当ててください。"
  exit 1
fi
if [ ! -f "$C.before-tv" ]; then cp "$C" "$C.before-tv"; fi
if ! grep -q "PATCHED-MIELE-TV" "$P"; then
  cp "$P" "$P.before-tv"
  echo "バックアップを作成しました: $P.before-tv"
fi

python3 - "$C" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if "programIdOverride" not in s:
    reps = [
     ("MieleWritableBinaryStateCharacteristic.prototype.patchedAutoStart = async function (actions) {",
      "MieleWritableBinaryStateCharacteristic.prototype.patchedAutoStart = async function (actions, programIdOverride) {  // PATCHED-MIELE-TV"),
     ("const programId = Number(this.platform.config.dishwasherProgramId) || 7;",
      "const programId = Number(programIdOverride) || Number(this.platform.config.dishwasherProgramId) || 7;"),
    ]
    for old, new in reps:
        if s.count(old) != 1:
            print("エラー: 想定と違うコードです:", p)
            sys.exit(1)
        s = s.replace(old, new)
    open(p, 'w', encoding='utf-8').write(s)
    print("開始処理にプログラム番号を渡せるようにしました。")
PYEOF

cat > "$T" <<'JSEOF'
"use strict";
// PATCHED-MIELE-TV: expose the dishwasher as a Television accessory (programs as inputs)
const axios = require('axios').default;
const settings = require('./settings');
const chars = require('./mieleCharacteristics');

const DEFAULT_PROGRAMS = [
    { name: 'エコ', programId: 3 },
    { name: 'オート', programId: 7 },
    { name: 'スピード', programId: 13 },
];

exports.publish = function (platform, devices) {
    if (platform.config.dishwasherTv === false || platform.patchedTvPublished) {
        return;
    }
    platform.patchedTvPublished = true;
    const hap = platform.api.hap;
    const Service = hap.Service;
    const Characteristic = hap.Characteristic;
    const autoStart = chars.MieleWritableBinaryStateCharacteristic.prototype.patchedAutoStart;
    let programs = platform.config.dishwasherPrograms;
    if (!Array.isArray(programs) || programs.length === 0) {
        programs = DEFAULT_PROGRAMS;
    }
    const accessories = [];

    for (const serial of Object.keys(devices)) {
        const dev = devices[serial];
        if (!dev.ident || !dev.ident.type || dev.ident.type.value_raw !== 7) {
            continue;
        }
        const name = platform.config.dishwasherTvName ||
            dev.ident.deviceName || dev.ident.type.value_localized || 'Dishwasher';
        const actionsUrl = platform.getActionsUrl(serial);
        const devUrl = actionsUrl.replace(/\/actions$/, '');
        const ctx = { platform: platform, serialNumber: serial, deviceName: name };
        const log = (msg) => platform.log.info(`${name} (TV): ${msg}`);

        const external = platform.config.dishwasherTvExternal !== false;
        const uuid = hap.uuid.generate(serial + (external ? '-patched-tv' : '-patched-tv-bridged'));
        let acc = external ? null : (platform.accessories || []).find((a) => a.UUID === uuid);
        const isNew = !acc;
        if (!acc) {
            acc = new platform.api.platformAccessory(name, uuid, hap.Categories.TELEVISION);
        }
        acc.category = hap.Categories.TELEVISION;
        acc.getService(Service.AccessoryInformation)
            .setCharacteristic(Characteristic.Manufacturer, 'Miele')
            .setCharacteristic(Characteristic.Model, (dev.ident.deviceIdentLabel || {}).techType || 'Dishwasher')
            .setCharacteristic(Characteristic.SerialNumber, serial + '-tv');

        const tv = acc.getServiceById(Service.Television, 'tv') || acc.addService(Service.Television, name, 'tv');
        tv.setCharacteristic(Characteristic.ConfiguredName, name);
        tv.setCharacteristic(Characteristic.SleepDiscoveryMode,
            Characteristic.SleepDiscoveryMode.ALWAYS_DISCOVERABLE);

        let active = 0;
        const NONE_ID = 999;  // placeholder input: "select a program"
        const CANCEL_ID = 997;  // status input: program cancelled
        const DONE_ID = 998;    // status input: program finished
        let activeId = NONE_ID;
        const showStatus = (id) => {
            if (activeId !== id) {
                activeId = id;
                tv.updateCharacteristic(Characteristic.ActiveIdentifier, id);
            }
        };
        const resetSelection = () => {
            activeId = NONE_ID;
            tv.updateCharacteristic(Characteristic.ActiveIdentifier, NONE_ID);
        };

        tv.getCharacteristic(Characteristic.Active)
            .onGet(() => active)
            .onSet(async (value) => {
            try {
                const cfg = platform.getHttpRequestConfig();
                const actions = (await axios.get(actionsUrl, cfg)).data;
                if (value) {
                    if (actions.powerOn) {
                        log('Powering on.');
                        try {
                            await axios.put(actionsUrl, { powerOn: true }, cfg);
                        }
                        catch (e) {
                            // Miele often answers 500 although the appliance powers on.
                        }
                    }
                    active = 1;
                    resetSelection();
                }
                else {
                    const running = (actions.processAction || []).includes(2);
                    if (running && platform.config.dishwasherTvDisableStop) {
                        log('Stop is disabled by configuration.');
                        setTimeout(() => tv.updateCharacteristic(Characteristic.Active, 1), 1000);
                        return;
                    }
                    if (running) {
                        log('Stopping program.');
                        await axios.put(actionsUrl, { processAction: 2 }, cfg);
                    }
                    else if (actions.powerOff) {
                        log('Powering off.');
                        await axios.put(actionsUrl, { powerOff: true }, cfg);
                    }
                    active = 0;
                    resetSelection();
                }
            }
            catch (e) {
                platform.log.error(`${name} (TV): ${e}`);
            }
        });

        tv.getCharacteristic(Characteristic.ActiveIdentifier)
            .onGet(() => activeId)
            .onSet(async (value) => {
            const prog = programs[Number(value) - 1];
            if (!prog) {
                // placeholder or status entries: nothing to start
                const keep = activeId;
                setTimeout(() => tv.updateCharacteristic(Characteristic.ActiveIdentifier, keep), 500);
                return;
            }
            activeId = Number(value);
            try {
                log(`Program "${prog.name}" (${prog.programId}) selected.`);
                const actions = (await axios.get(actionsUrl, platform.getHttpRequestConfig())).data;
                if (await autoStart.call(ctx, actions, prog.programId)) {
                    active = 1;
                    tv.updateCharacteristic(Characteristic.Active, 1);
                }
            }
            catch (e) {
                platform.log.error(`${name} (TV): ${e}`);
            }
        });

        tv.getCharacteristic(Characteristic.RemoteKey).onSet(() => { /* no remote keys */ });

        const wantedInputs = ['input-none'].concat(programs.map((p) => 'input-' + p.programId));
        const none = acc.getServiceById(Service.InputSource, 'input-none') ||
            acc.addService(Service.InputSource, 'プログラムを選択', 'input-none');
        none
            .setCharacteristic(Characteristic.Identifier, NONE_ID)
            .setCharacteristic(Characteristic.ConfiguredName, '（プログラムを選択）')
            .setCharacteristic(Characteristic.IsConfigured, Characteristic.IsConfigured.CONFIGURED)
            .setCharacteristic(Characteristic.InputSourceType, Characteristic.InputSourceType.OTHER)
            .setCharacteristic(Characteristic.CurrentVisibilityState, Characteristic.CurrentVisibilityState.SHOWN);
        tv.addLinkedService(none);
        for (const [sub, id, label] of [['input-status-cancel', CANCEL_ID, 'プログラム中止'], ['input-status-done', DONE_ID, '終了']]) {
            wantedInputs.push(sub);
            const svc = acc.getServiceById(Service.InputSource, sub) || acc.addService(Service.InputSource, label, sub);
            svc
                .setCharacteristic(Characteristic.Identifier, id)
                .setCharacteristic(Characteristic.ConfiguredName, label)
                .setCharacteristic(Characteristic.IsConfigured, Characteristic.IsConfigured.CONFIGURED)
                .setCharacteristic(Characteristic.InputSourceType, Characteristic.InputSourceType.OTHER)
                .setCharacteristic(Characteristic.CurrentVisibilityState, Characteristic.CurrentVisibilityState.SHOWN);
            tv.addLinkedService(svc);
        }
        for (const svc of acc.services.slice()) {
            if (svc.UUID === Service.InputSource.UUID && !wantedInputs.includes(svc.subtype)) {
                tv.removeLinkedService(svc);
                acc.removeService(svc);
            }
        }
        programs.forEach((prog, i) => {
            const subtype = 'input-' + prog.programId;
            const input = acc.getServiceById(Service.InputSource, subtype) ||
                acc.addService(Service.InputSource, prog.name, subtype);
            input
                .setCharacteristic(Characteristic.Identifier, i + 1)
                .setCharacteristic(Characteristic.ConfiguredName, prog.name)
                .setCharacteristic(Characteristic.IsConfigured, Characteristic.IsConfigured.CONFIGURED)
                .setCharacteristic(Characteristic.InputSourceType, Characteristic.InputSourceType.OTHER)
                .setCharacteristic(Characteristic.CurrentVisibilityState, Characteristic.CurrentVisibilityState.SHOWN);
            tv.addLinkedService(input);
        });

        // Keep the power state in sync with the appliance.
        const poll = async () => {
            try {
                const st = (await axios.get(devUrl + '/state', platform.getHttpRequestConfig())).data;
                const raw = st.status ? st.status.value_raw : 1;
                const now = raw !== 1 ? 1 : 0;
                if (now !== active) {
                    active = now;
                    tv.updateCharacteristic(Characteristic.Active, active);
                    if (!active) {
                        resetSelection();
                    }
                }
                if (raw === 9) {         // Cancelled
                    showStatus(CANCEL_ID);
                }
                else if (raw === 7) {    // Finished
                    showStatus(DONE_ID);
                }
                else if ((activeId === CANCEL_ID || activeId === DONE_ID) && raw !== 5) {
                    resetSelection();
                }
            }
            catch (e) {
                platform.log.debug(`${name} (TV): state poll failed: ${e}`);
            }
        };
        setInterval(poll, 30 * 1000);
        setTimeout(poll, 5 * 1000);

        if (external) {
            accessories.push(acc);
            platform.log.info(`${name}: Publishing TV-style accessory (external) with ${programs.length} programs.`);
        }
        else if (isNew) {
            platform.api.registerPlatformAccessories(settings.PLUGIN_NAME, settings.PLATFORM_NAME, [acc]);
            platform.log.info(`${name}: Registering TV-style accessory (bridged) with ${programs.length} programs.`);
        }
        else {
            platform.api.updatePlatformAccessories([acc]);
            platform.log.info(`${name}: Updating TV-style accessory (bridged) with ${programs.length} programs.`);
        }
    }

    if (accessories.length > 0) {
        platform.api.publishExternalAccessories(settings.PLUGIN_NAME, accessories);
    }
};
JSEOF

python3 - "$P" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if "PATCHED-MIELE-TV" in s:
    print("platform.js はパッチ済みです（テレビ型の部分だけ更新しました）。")
    sys.exit(0)
old = """                            `with raw type value: ${device.ident.type.value_raw}.`);
                    }
                }
            }
        }
        catch (response) {"""
new = """                            `with raw type value: ${device.ident.type.value_raw}.`);
                    }
                }
            }
            // PATCHED-MIELE-TV
            require('./patchedDishwasherTv').publish(this, response.data);
        }
        catch (response) {"""
if s.count(old) != 1:
    print("エラー: 想定と違うコードです。ファイルは変更していません。")
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
print("パッチを当てました。")
PYEOF

node --check "$P" && node --check "$T" && node --check "$C" && echo "構文チェック OK"
echo "Homebridge を再起動してください: sudo hb-service restart"
