# n8n-on-azure-paas（日本語）

[English](README.md)

n8n を、PaaS だけで動かす検証用の Bicep サンプルです（**AVM のモジュールだけ**で構成しています）。
永続的な運用ではなく、作って、検証して、リソースグループごと削除する使い方を想定しています。

## 構成

| 役割 | サービス | AVM モジュール |
|---|---|---|
| アプリ（n8n 2.46.6） | Container Apps（Consumption、1 レプリカ、1 vCPU / 2GiB） | `app/container-app`、`app/managed-environment` |
| DB（状態のすべて） | Azure Database for PostgreSQL フレキシブルサーバー（B1ms、VNet 統合） | `db-for-postgre-sql/flexible-server` |
| ネットワーク | VNet（2 サブネット）、Private DNS ゾーン | `network/virtual-network`、`network/private-dns-zone` |
| ログ | Log Analytics | `operational-insights/workspace` |

- n8n の DB を SQLite のままネットワーク共有（Azure Files）に置くのは相性が悪いため、PostgreSQL に切り出しています（`DB_TYPE=postgresdb`）。コンテナにボリュームは付けません。
- 複数の main（複数レプリカ）は、n8n の Enterprise 向けの機能です。レプリカは 1 つ（最小 1、最大 1）に固定しています。
- 外部に公開されるのは、n8n の入り口（Container Apps の ingress）だけです。PostgreSQL は公開アクセスを無効にしています。
- `N8N_WEBHOOK_URL` は、環境の既定ドメインから組み立てています（アプリ自身の出力を参照すると循環するため）。`N8N_PROXY_HOPS=1` も設定しています。

## 重要：暗号化キーを固定する

ボリュームなしの構成では、`N8N_ENCRYPTION_KEY` を固定の値で渡す必要があります。
未設定、または別の値だと、n8n は起動に失敗します（コンテナを作り直すと、鍵が変わるため）。

```text
Deployment key 'signing.hmac' cannot be read with this instance encryption key
```

`deploy.sh` は、初回のデプロイで鍵を生成し、2 回目以降は、既存のアプリのシークレット（`encryption-key`）から同じ値を取り出して使います。
鍵は保存しません。リソースグループを削除すると、鍵も失われます。

## 重要：IP 制限をかける

n8n は、**最初にアクセスした人が、オーナーのアカウントを作る**作りです。
URL が公開されるので、デプロイしてから自分でアカウントを作るまでの間に、誰かに先に取られる可能性があります。n8n はコードを実行できるので、乗っ取られると影響が大きいです。

`-i` で、許可する送信元 IP（CIDR）を渡してください。省略すると、警告が出て、インターネットに開いたままになります。

## デプロイ

```bash
./deploy.sh -s "<subscription>" -i "<自分のIP>/32"             # what-if のみ
./deploy.sh -s "<subscription>" -i "<自分のIP>/32" --apply     # デプロイ
```

| オプション | 意味 |
|---|---|
| `-s` | サブスクリプション（必須） |
| `-g` | リソースグループ名（既定：`rg-n8n-paas`。なければ作成） |
| `-i` | 許可する送信元 IP / CIDR（カンマ区切り） |
| `-u` | PostgreSQL の管理者名（既定：`n8nadmin`） |
| `-p` | PostgreSQL の管理者パスワード |
| `--apply` | what-if のあと、実際にデプロイ |

- パスワードを省略すると、`main.bicep` が `uniqueString` から作ります。**`uniqueString` は、サブスクリプションと RG の ID から決まる値で、ランダムではありません**。PostgreSQL は、公開アクセスを無効にした検証用なので、許容しています。それ以外の用途では、`-p` で指定してください。
- 環境変数（`PG_ADMIN_LOGIN`、`PG_ADMIN_PASSWORD`、`N8N_ENCRYPTION_KEY`、`ALLOWED_IPS`）でも渡せます。
- デプロイ後の URL は、出力の `n8nUrl` に出ます。オーナーのアカウントは、ブラウザでその URL を開いて作ります。
- `what-if` には、VNet のサブネットなどに、実際には変わらない差分が出ることがあります。

検証が終わったら、リソースグループごと削除します。

```bash
az group delete -n rg-n8n-paas --subscription "<subscription>" --yes
```

Container Apps の環境は、`ME_` で始まる別のリソースグループ（Load Balancer と IP）を自動で作ります。リソースグループの削除で、一緒に消えることを確認してください。

## 検証結果（2026-11-09）

東日本、検証用のサブスクリプションで確認したものです。

- `/healthz` と `/healthz/readiness` が 200 を返す。PostgreSQL にマイグレーションが通り、`Editor is now accessible` までログに出る。
- webhook（`GET /webhook/…`）が 200 で値を返す。
- コンテナを再起動して新しいレプリカになっても、ワークフロー、有効化の状態、実行履歴が残る。
- CPU は、アイドル時に 1 時間平均で 3.4〜3.8 ミリコア（アイドルの条件は 0.01 コア未満）。環境変数の調整なしで、アイドル料金で課金された。

## 費用の実績

Cost Management（ActualCost）の 1 日あたりです（2026-11-07〜08）。

| 項目 | 1 日あたり |
|---|---|
| PostgreSQL B1ms（コンピュート） | 約 99 円 |
| PostgreSQL ストレージ | 約 23 円 |
| Private DNS ゾーン | 約 3 円 |
| Container Apps の環境の基盤：Load Balancer（`ME_` の RG） | 約 95 円 |
| 同：パブリック IP | 約 19 円 |
| **合計（Container Apps 本体を除く）** | **約 239 円** |

- Container Apps 本体は、デプロイから約 2 日間は請求に出ませんでした。月ごとの無料枠（180,000 vCPU 秒、360,000 GiB 秒）に入っていたためと推測しています（要確認）。
- 無料枠のあとは、1 vCPU / 2GiB で約 124 円/日（2026-11-09 の丸 1 日。アイドル料金で、vCPU とメモリとも約 0.000475 円/秒）でした。Active の割合は、秒数で約 1.6％です。
- 合計は、無料枠のあとで約 363 円/日（11/9）、月に約 10,900 円（概算）です。
- 含めていないもの：Log Analytics、通信量。

## やっていないこと

- n8n のライセンス条件の確認（個人利用、社内利用の可否は、公式で確認してください）
- ボリュームなしで、大きなファイル（バイナリデータ）を扱うワークフロー
- キューモード（Redis）と、複数レプリカ
- カスタムドメインとマネージド証明書
- Key Vault（秘密情報は、Container App のシークレットに入れています）
