# mitmproxy CA証明書を Android エミュレータのシステム証明書として登録する手順

mitmproxy の CA 証明書を Android **システムレベル**の信頼済み CA としてインストールする手順書です。

Android 7 (API 24) 以降、アプリは既定で**ユーザーが追加した CA 証明書を信頼しません**（`network_security_config` で明示的に許可したアプリのみ信頼）。多くのアプリの HTTPS 通信を傍受するには、CA を**システム証明書ストア**に入れる必要があります。

> ⚠️ システム証明書ストアの書き換えには **root 化可能なエミュレータ**が必要です。

---

## 0. 前提条件

| 項目 | 内容 |
|------|------|
| エミュレータイメージ | **Google APIs** 版を使用（**Google Play** 版は本番同様 root 不可）。`-writable-system` を使う場合も Play 版は不可。 |
| adb | Android SDK Platform-Tools に含まれる `adb` が PATH 上にあること |
| openssl | 証明書ハッシュ名の算出に使用（Docker / Git for Windows / WSL に同梱） |
| CA証明書 | `start-mitmproxy.*` を一度起動して `./certs/mitmproxy-ca-cert.pem` が生成済みであること |

接続中のデバイスを確認:

```bash
adb devices
```

エミュレータの Android バージョン確認:

```bash
adb shell getprop ro.build.version.release   # 例: 13
adb shell getprop ro.build.version.sdk       # 例: 33
```

---

## 1. mitmproxy を起動して証明書を生成する

まだ証明書が無い場合は、まずプロキシを一度起動します。

```bash
# Linux / macOS / WSL
./start-mitmproxy.sh

# Windows
start-mitmproxy.bat
```

`./certs/` に以下が生成されます。

- `mitmproxy-ca-cert.pem` … システム証明書として使う CA（PEM形式・公開鍵のみ）
- `mitmproxy-ca-cert.cer` … 端末へ手動インストールする際のユーザー証明書（同内容）
- `mitmproxy-ca.pem` … **秘密鍵を含む**ファイル（**外部に出さないこと**）

---

## 2. エミュレータのプロキシを設定する

ホスト PC で動く mitmproxy（ポート 8080）へエミュレータの通信を向けます。
エミュレータからホスト PC は **`10.0.2.2`** で参照できます。

**方法A: 起動時に指定（推奨）**

```bash
emulator -avd <AVD名> -http-proxy http://10.0.2.2:8080 -writable-system
```

**方法B: 設定画面から**

`設定 > ネットワークとインターネット > インターネット > (接続中のWi-Fi) > プロキシ > 手動`
- ホスト名: `10.0.2.2`
- ポート: `8080`

> `-writable-system` は後段でシステム領域を書き換えるために必要です（後述）。

### プロキシ認証（パスワード）を有効にした場合

`.env`（`.env.example` をコピーして作成）で `MITM_PROXY_PASS` を設定すると、
プロキシ利用時にユーザー名／パスワードが要求されます（mitmproxy の `proxyauth`）。

```
MITM_PROXY_USER=mitmproxy
MITM_PROXY_PASS=secret123
```

この場合、端末側のプロキシにも認証情報が必要です。
- `curl` で確認する場合: `-x http://mitmproxy:secret123@10.0.2.2:8080`
- GUI のプロキシ設定では、ユーザー名／パスワード欄に同じ値を入力します。

認証なし（既定）で使う場合は `MITM_PROXY_PASS` を空のままにします。

接続確認（プロキシ越しに mitmproxy が動いているか）:

```bash
adb shell curl -x http://10.0.2.2:8080 http://mitm.it -s | head
```

---

## 3. 証明書を Android 形式のファイル名に変換する

Android のシステム証明書は `<subject_hash_old>.0` という名前で配置する必要があります。

**Linux / macOS / WSL:**

```bash
cd certs
HASH=$(openssl x509 -inform PEM -subject_hash_old -in mitmproxy-ca-cert.pem | head -1)
cp mitmproxy-ca-cert.pem "${HASH}.0"
echo "生成: ${HASH}.0"
```

**Windows (PowerShell, openssl が PATH 上にある場合):**

```powershell
cd certs
$HASH = (openssl x509 -inform PEM -subject_hash_old -in mitmproxy-ca-cert.pem | Select-Object -First 1)
Copy-Item mitmproxy-ca-cert.pem "$HASH.0"
Write-Host "生成: $HASH.0"
```

**openssl が無い場合は Docker 経由で算出:**

```bash
docker run --rm -v "$(pwd)/certs:/c" -w /c mitmproxy/mitmproxy \
  sh -c 'cp mitmproxy-ca-cert.pem "$(openssl x509 -inform PEM -subject_hash_old -in mitmproxy-ca-cert.pem | head -1).0"'
```

以降、生成された `<HASH>.0`（例: `c8750f0d.0`）を使います。

---

## 4. システム証明書ストアへ登録する

Android のバージョンによって手順が異なります。**お使いのバージョンの節だけ**実施してください。

### 方法 A — Android 9 (Pie) 以下 / `-writable-system` 起動済み

最も簡単な方法です。

```bash
adb root
adb remount        # 失敗する場合は方法Bを参照

# Android 形式の証明書を配置
adb push c8750f0d.0 /sdcard/         # まず一時領域へ
adb shell su -c "mv /sdcard/c8750f0d.0 /system/etc/security/cacerts/"
adb shell su -c "chmod 644 /system/etc/security/cacerts/c8750f0d.0"
adb shell su -c "chown root:root /system/etc/security/cacerts/c8750f0d.0"

adb reboot
```

> `adb push c8750f0d.0 /system/etc/security/cacerts/` を直接実行できる場合もあります。
> `chcon` が必要な環境では `adb shell su -c "chcon u:object_r:system_security_cacerts_file:s0 /system/etc/security/cacerts/c8750f0d.0"` を追加してください。

### 方法 B — Android 10〜13 (`/system` が読み取り専用の場合)

エミュレータを必ず **`-writable-system`** 付きで起動しておきます。

```bash
# 1. 検証を無効化して書き込み可能にする
adb root
adb shell avbctl disable-verification   # 失敗しても続行可（環境による）
adb reboot

# 2. 再 root して remount
adb root
adb remount         # "remount succeeded" が出れば OK

# 3. 証明書を配置
adb push c8750f0d.0 /system/etc/security/cacerts/
adb shell chmod 644 /system/etc/security/cacerts/c8750f0d.0

adb reboot
```

`adb remount` が失敗する場合は、いったんエミュレータを終了し
`-writable-system` 付きで起動し直してから再実行してください。

### 方法 C — Android 14 (API 34) 以降

Android 14 ではシステム CA が `/system/etc/security/cacerts/` から
**APEX (`/apex/com.android.conscrypt/cacerts/`)** に移動しました。
ファイルを置き換えるだけでは反映されないため、tmpfs オーバーレイでマウントし直します。

エミュレータは **`-writable-system`** 付きで起動しておきます。

```bash
adb root
adb remount

# 1. 既存のシステムCAを一時ディレクトリにコピー
adb shell 'mkdir -p -m 755 /data/local/tmp/cacerts'
adb shell 'cp /apex/com.android.conscrypt/cacerts/* /data/local/tmp/cacerts/'

# 2. 自前のCAを追加し、属性を揃える
adb push c8750f0d.0 /data/local/tmp/cacerts/
adb shell 'chmod 644 /data/local/tmp/cacerts/*'
adb shell 'chcon u:object_r:system_file:s0 /data/local/tmp/cacerts/*'

# 3. システムの cacerts に tmpfs を被せて全CAを書き込む
adb shell 'mount -t tmpfs tmpfs /system/etc/security/cacerts'
adb shell 'cp /data/local/tmp/cacerts/* /system/etc/security/cacerts/'
adb shell 'chown root:root /system/etc/security/cacerts/*'
adb shell 'chmod 644 /system/etc/security/cacerts/*'
adb shell 'chcon u:object_r:system_security_cacerts_file:s0 /system/etc/security/cacerts/*'

# 4. 起動中の全プロセスの mount namespace に APEX へバインドマウント
adb shell 'for pid in $(pgrep -af . | cut -d" " -f1); do \
  nsenter --mount=/proc/$pid/ns/mnt -- \
    /bin/mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts; \
done 2>/dev/null'
```

> この方法は**再起動すると失われます**（tmpfs のため）。再起動後は手順 C を再実行してください。
> 詳細な解説は HTTP Toolkit のブログ "Android 14 install system CA certificate" を参照。

---

## 5. 登録の確認

### ファイルが存在するか

```bash
adb shell ls -l /system/etc/security/cacerts/ | grep c8750f0d
# Android 14 はこちらも確認
adb shell ls -l /apex/com.android.conscrypt/cacerts/ | grep c8750f0d
```

### GUI で確認

`設定 > セキュリティとプライバシー > その他のセキュリティ設定 > 暗号化と認証情報 > 信頼できる認証情報 > システム`
の一覧に **mitmproxy** が表示されていれば成功です（「ユーザー」タブではなく「システム」タブ）。

### 実通信で確認

エミュレータ上のブラウザやアプリで HTTPS サイトを開き、mitmproxy（`mitmweb` の場合は `http://127.0.0.1:8081`）に
復号済みの通信が表示されれば成功です。証明書エラーが出なければシステム CA として信頼されています。

---

## 6. トラブルシューティング

| 症状 | 対処 |
|------|------|
| `adb remount` が `Permission denied` / 失敗 | エミュレータを `-writable-system` 付きで再起動。Google **Play** 版イメージでは不可 → Google **APIs** 版を使う。 |
| `adb root` が `adbd cannot run as root in production builds` | Play 版イメージ。APIs 版 AVD を作り直す。 |
| 証明書を入れても HTTPS で証明書エラー | ファイル名が `<subject_hash_old>.0` になっているか、`subject_hash_old`（`-subject_hash` ではない）で算出したか確認。配置後に `adb reboot`。 |
| 「ユーザー」タブには出るが「システム」に出ない | 手順4を未実施。ユーザー証明書はアプリに信頼されない。 |
| Android 14 で反映されない | 方法 C（tmpfs オーバーレイ）を実施。再起動後は再実行が必要。 |
| アプリだけ傍受できない（ブラウザはOK） | 証明書ピンニング（certificate pinning）の可能性。Frida 等でのバイパスが別途必要。 |
| プロキシに通信が来ない | エミュレータのプロキシが `10.0.2.2:8080` か、mitmproxy が起動中か（`docker ps`）確認。 |

---

## 付録: ユーザー証明書として手早く入れる（システムにしない簡易版）

システム化が不要な検証用途では、ユーザー証明書として入れるだけでも
`network_security_config` で user CA を許可しているアプリ／自作アプリは傍受できます。

```bash
adb push certs/mitmproxy-ca-cert.cer /sdcard/Download/
```

`設定 > セキュリティ > 暗号化と認証情報 > 証明書をインストール > CA証明書`
から `/sdcard/Download/mitmproxy-ca-cert.cer` を選択してインストールします。

---

## 付録: MEmu (Android 9) + Windows Docker での実施手順（検証済み）

この環境で実際に動作確認した具体的な手順です。`adb` は
`local/android-platform-tools/adb.exe` を使用します。MEmu は QEMU の
`10.0.2.2` が使えないため、**`adb reverse` でプロキシ経路を作る**点が
通常のエミュレータと異なります。

PowerShell での例（パスは環境に合わせて調整）:

```powershell
$adb  = "local\android-platform-tools\adb.exe"

# 1. mitmproxy を起動（初回に certs\ が生成される）
.\start-mitmproxy.bat web

# 2. MEmu の adb ポートを特定して接続
#    MEmu の adb ポートは 21503 から。複数インスタンスは +10 ずつ
#    (21513, 21523, ...)。不明なら listen ポートを確認:
#    Get-NetTCPConnection -State Listen | ? {(Get-Process -Id $_.OwningProcess).ProcessName -like 'MEmu*'}
& $adb connect 127.0.0.1:21513
$dev = "127.0.0.1:21513"

# 3. MEmu は adbd が最初から root。/system を書き込み可能にする
& $adb -s $dev root
& $adb -s $dev remount        # "remount succeeded"

# 4. CA のハッシュ名 (<subject_hash_old>.0) を算出（openssl はコンテナ内を使用）
$hash = (docker exec mitmproxy-emu sh -c "openssl x509 -inform PEM -subject_hash_old -in /home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem | head -1").Trim()
docker exec mitmproxy-emu sh -c "cp /home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem /home/mitmproxy/.mitmproxy/$hash.0"

# 5. システム証明書ストアへ配置
& $adb -s $dev push "certs\$hash.0" /sdcard/$hash.0
& $adb -s $dev shell "cp /sdcard/$hash.0 /system/etc/security/cacerts/$hash.0 && chmod 644 /system/etc/security/cacerts/$hash.0 && chown root:root /system/etc/security/cacerts/$hash.0 && rm /sdcard/$hash.0"
& $adb -s $dev shell "chcon u:object_r:system_security_cacerts_file:s0 /system/etc/security/cacerts/$hash.0"

# 6. 再起動して反映
& $adb -s $dev reboot
# ブート完了まで待機（getprop sys.boot_completed が 1 になるまで）

# 7. プロキシ経路を作る（MEmu では 10.0.2.2 が使えないため adb reverse）
& $adb -s $dev root
& $adb -s $dev reverse tcp:8080 tcp:8080
& $adb -s $dev shell "settings put global http_proxy 127.0.0.1:8080"
```

### 動作確認（システム信頼ストア経由か検証）

`curl` は Android のシステム CA ストア（`/system/etc/security/cacerts`）を
使うため、`-k` 無しで成功すればシステム証明書として信頼されています。

```powershell
& $adb -s $dev shell 'curl -s -o /dev/null -w "HTTP=%{http_code} verify=%{ssl_verify_result}\n" -x http://127.0.0.1:8080 https://example.com'
# => HTTP=200 verify=0  （verify=0 = 検証成功）
```

### 注意点

- **`adb reverse` と グローバルプロキシは端末の再起動／adb 切断で消えます。**
  再起動後は手順 7（`adb root` → `reverse` →（必要なら）`settings put global http_proxy`）を再実行してください。
- グローバルプロキシを解除して通常のネットワークに戻すには:
  ```powershell
  & $adb -s $dev shell "settings put global http_proxy :0"
  ```
- ホストの `10.0.2.2:8080` や NAT ゲートウェイ経由は Docker Desktop の
  ネットワーク構成では届かないことがあります（本環境では `HTTP=000`）。
  確実なのは `adb reverse` 方式です。
