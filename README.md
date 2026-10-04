# homebridge-mieleathome 食洗機パッチ集（ホームアプリから電源オン・プログラム選択・開始）

[homebridge-mieleathome](https://github.com/QuickSander/homebridge-mieleathome) v3.5.0 に当てる修正スクリプト集です。
Miele の食洗機を、iPhone のホームアプリ（HomeKit）や Siri から「電源オン → プログラムを選んで開始」できるようにします。

## こんな方へ

- ホームアプリに食洗機（蛇口のアイコン）は出るが、オンにしても動かない
- Miele アプリでは開始できるのに、Homebridge からは開始できない
- ログに `not allowed in current device state. Allowed Miele process actions:` と出る
- ホームアプリで残り時間を見たい、プログラムを選びたい

## 原因

Miele の外部向け API では、食洗機の「開始」命令（`processAction`）が許可されないことがあります。
一方で、本体の設定で **MobileStart をオン**にしておくと、「電源オン（`powerOn`）→ プログラム指定（`PUT /programs`）」の2つの命令で洗浄が始まります（G5844 で確認）。
元のプラグインは「開始」命令しか使わないため、開始できませんでした。

## パッチの一覧

| ファイル | 内容 | 必須 |
|---|---|---|
| `miele-autostart-patch.sh` | ホームアプリで食洗機をオンにすると「電源オン → プログラム指定 → 開始」を行う | ○（ほかのパッチの前提） |
| `miele-duration-patch.sh` | 蛇口型をスプリンクラー型にして、ホームアプリに残り時間を表示する | 任意 |
| `miele-tv-patch.sh` | テレビ型の操作画面を追加（電源ボタン＋入力切り替えの一覧でプログラムを選ぶと開始。中止・終了も表示） | 任意 |
| `miele-programs-patch.sh` | プログラムごとのスイッチを追加（押すとそのプログラムで開始） | 任意 |
| `miele-check.py` | 食洗機に対して API で何ができるかを調べる（読み取りのみ） | 診断用 |

## 前提

- homebridge-mieleathome **v3.5.0**（それ以外の版では「想定と違うコードです」と出て、何も変更しません）
- 食洗機本体の設定で **リモートコントロール** と **MobileStart** がオン
- Raspberry Pi などで Homebridge が動いていること

## 使い方

Homebridge が動いている機器で、スクリプトを実行してから Homebridge を再起動します。

```
sudo bash miele-autostart-patch.sh
sudo bash miele-duration-patch.sh     # 任意
sudo bash miele-tv-patch.sh           # 任意
sudo hb-service restart
```

- 何度実行しても安全です（当て済みなら何もしません）。
- 元に戻すときは、それぞれ `restore` を付けて実行します（例：`sudo bash miele-tv-patch.sh restore`）。
- プラグインを更新・再インストールすると修正は消えます。同じ手順で当て直してください。

テレビ型は独立した機器として公開されます。ホームアプリの「アクセサリを追加」→「その他のオプション」から選び、Homebridge のセットアップコードを入力して追加してください（iPhone で一覧に出ない場合は、iPad で試すと出ることがあります）。

## 設定（config.json の Miele@home の項目、すべて省略可）

```json
"dishwasherProgramId": 7,
"dishwasherPrograms": [
  { "name": "オート", "programId": 7 },
  { "name": "エコ", "programId": 3 },
  { "name": "クイックパワーウォッシュ", "programId": 13 }
],
"dishwasherTvName": "食洗機",
"dishwasherTvDisableStop": true
```

- `dishwasherProgramId`：蛇口／スプリンクラー型のボタンで開始するプログラム（省略時 7 = Auto）
- `dishwasherPrograms`：テレビ型の一覧・プログラムスイッチに出すプログラム。番号は `miele-check.py` で確認できます
- `dishwasherTvDisableStop`：洗浄中にテレビ型の電源ボタンで止めない
- `dishwasherTvExternal`：`false` にすると、テレビ型を独立した機器ではなくブリッジ経由で登録します

## 注意

- **食器と洗剤を入れてから**操作してください。入っていなくても、そのまま洗浄が始まります。
- 本体の MobileStart がオフのときは、パッチは何もしません。
- 電源オンの命令に Miele の API がエラー（500）を返すことがありますが、実際には電源が入ります。パッチはこれを無視して処理を続けます。

## 動作確認

Miele G5844、homebridge-mieleathome v3.5.0、Homebridge v1.11.1、Raspberry Pi

## ライセンス

元のプラグインと同じ Apache License 2.0 です（LICENSE を参照）。
これらのスクリプトは、homebridge-mieleathome（Copyright (c) 2020, Sander van Woensel）のファイルを変更するものです。

---

# English summary

Patch scripts for [homebridge-mieleathome](https://github.com/QuickSander/homebridge-mieleathome) v3.5.0 that let the Home app start a Miele dishwasher from power-off.

The Miele 3rd-party API often does not allow `processAction: Start` for dishwashers. With MobileStart enabled on the appliance, `powerOn` followed by `PUT /devices/{id}/programs {programId}` starts the program (tested on G5844). The patches add:

- **autostart**: valve "on" → power on → select program → start (required by the others)
- **duration**: irrigation-type valve + SetDuration so the Home app shows the remaining time
- **tv**: a Television accessory; inputs are programs, selecting one starts it; shows "cancelled"/"finished"
- **programs**: one momentary switch per program

Run `sudo bash <script>` and restart Homebridge; `restore` reverts. Licensed under Apache-2.0, same as the original plugin.
