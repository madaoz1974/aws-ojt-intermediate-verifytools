# AWS リソース検証環境

このプロジェクトは、AWS上に構築されたアプリケーション環境のリソースを検証するためのDev Container環境です。

## はじめに

AWSインフラ環境の成果物をレビューする際、こんな課題はありませんか？

- CloudFrontの設定が正しいか確認するために、毎回AWSコンソールにログインするのが面倒
- ALBのヘルスチェック、EC2のIAMロール設定など、確認項目が多岐にわたる
- セキュリティグループの設定ミスを見落としてしまう
- 暗号化設定の確認が漏れやすい

これらの課題を解決する**AWS リソース検証ツール**を作成してみました。
Dev Containerを活用することで、環境構築不要ですぐに使えるツールになっています。

## プロジェクトの背景

このツールは、**AWS OJT 中級コース**における成果物レビューを効率化するために開発されました。

### 想定される研修シナリオ

受講者は以下のようなWebアプリケーション環境をAWS上に構築します：

- **フロントエンド**: CloudFront + S3（静的コンテンツ配信）
- **アプリケーション**: ALB + EC2（Tomcat）
- **データベース**: RDS（PostgreSQL）
- **ストレージ**: S3（動画ファイル保存）
- **セキュリティ**: IAM、Security Group、暗号化設定

### レビュー時の課題

これらのリソースが正しく構築されているかを確認するには、通常は以下の作業が必要です：

1. AWSコンソールにログインして各サービスの画面を確認
2. AWS CLIで個別にコマンドを実行して設定値を取得
3. 複数のリソース間の連携設定を手動で突き合わせ

**これを全て自動化したのが、このツールです。**

## ツールの特徴

### 1. Dev Containerで環境構築不要

```json
// .devcontainer/devcontainer.json
{
  "name": "AWS Verification Environment",
  "build": {
    "dockerfile": "Dockerfile"
  },
  "mounts": [
    "source=${localEnv:HOME}/.aws,target=/home/vscode/.aws,type=bind,consistency=cached"
  ]
}
```

VS Codeの「Dev Containers: Reopen in Container」を選択するだけで、必要なツール（AWS CLI、jq、curlなど）がすべて揃った環境が起動します。

### 2. 設定ファイルでリソースを指定

検証対象のAWSリソースは、設定ファイルで一元管理します：

```bash
# config/aws-config.sh
CLOUDFRONT_DISTRIBUTION_ID="E1234ABCD5678"
CLOUDFRONT_DOMAIN="d1234abcd5678.cloudfront.net"
ALB_ARN="arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:loadbalancer/app/movie-dev-app-alb/..."
S3_BUCKET_NAME="movie-dev-app-contents"
RDS_INSTANCE_ID="movie-dev-app-rds"
```

### 3. 包括的な検証項目

このツールでは、以下の8つのカテゴリで検証を実施します：

## 検証項目の詳細

### ① CloudFront検証

```bash
verify_cloudfront() {
    # Distribution の存在確認
    # /contents/ パスルーティングの設定確認
    # デプロイ状態の確認
}
```

**チェック内容**：
- CloudFront Distributionが存在するか
- `/contents/*` パスが正しくS3オリジンにルーティングされているか
- デプロイ状態が "Deployed" になっているか

### ② ALB検証

```bash
verify_alb() {
    # Load Balancer の存在確認
    # Target Group の設定確認
    # ヘルスチェックの正常性確認
}
```

**チェック内容**：
- ALBが存在し、正常に稼働しているか
- Target Groupに登録されたターゲットがすべて "healthy" か
- ヘルスチェックの設定が適切か

### ③ EC2検証

```bash
verify_ec2() {
    # インスタンスの実行状態確認
    # IAM Instance Profile の設定確認
    # Security Group の設定確認
    # SSM Agent の状態確認
}
```

**チェック内容**：
- EC2インスタンスが実行中（running）か
- IAM Instance Profileが設定されているか
- Security Groupが適切に設定されているか
- SSM Agentがオンラインか（Session Manager接続可能か）

### ④ Security Group検証

```bash
verify_security_groups() {
    # Security Group の参照設定確認
    # 0.0.0.0/0 からのアクセス制限確認
}
```

**チェック内容**：
- Security Group間の参照設定が正しいか
- `0.0.0.0/0` からの不要なアクセスが制限されているか
- インバウンドルールとアウトバウンドルールが適切か

### ⑤ RDS検証

```bash
verify_rds() {
    # RDS インスタンスの存在確認
    # カスタムパラメータグループの設定確認
    # データベースの存在確認
}
```

**チェック内容**：
- RDSインスタンスが稼働中（available）か
- デフォルトではないカスタムパラメータグループが使用されているか
- データベースが作成されているか（PostgreSQL 16）

### ⑥ S3検証

```bash
verify_s3() {
    # バケットの存在確認
    # 暗号化設定の確認
    # バケットポリシーの確認（CloudFront OAC、EC2 Role）
}
```

**チェック内容**：
- S3バケットが存在するか
- サーバー側暗号化が有効になっているか
- CloudFront（OAC）とEC2のIAM Roleからのアクセスが許可されているか

### ⑦ 暗号化検証

```bash
verify_encryption() {
    # EBS ボリュームの暗号化確認
    # RDS ストレージの暗号化確認
    # S3 バケットの暗号化確認
}
```

**チェック内容**：
- すべてのEBSボリュームが暗号化されているか
- RDSストレージが暗号化されているか
- S3バケットに暗号化設定があるか

### ⑧ アプリケーション正常性確認

```bash
verify_application_health() {
    # CloudFront ドメインへのHTTPS接続テスト
    # Tomcat アプリケーションの動作確認
}
```

**チェック内容**：
- CloudFrontのドメインにHTTPSで接続できるか
- Tomcatアプリケーションが正常に動作しているか

## 使い方

### 1. Dev Container環境の起動

```bash
# VS Codeでプロジェクトを開く
code .

# Command Palette (Cmd+Shift+P / Ctrl+Shift+P) を開く
# "Dev Containers: Reopen in Container" を選択
```

### 2. AWS認証情報の設定

```bash
# 現在の設定確認
aws sts get-caller-identity

# 設定が必要な場合
aws configure
```

### 3. 検証対象リソース情報の設定

```bash
# 設定ファイルのコピー
cp config/aws-config.template.sh config/aws-config.sh

# 設定ファイルの編集
vim config/aws-config.sh
```

### 4. 検証実行

```bash
# 全ての検証を実行
./scripts/verify-aws-resources.sh
```

### 5. 結果確認

検証結果はコンソールにリアルタイム表示されると同時に、ログファイルにも保存されます：

```
========================================
AWS リソース検証開始
========================================
実行時刻: Thu Oct 10 12:34:56 UTC 2025
ログファイル: /workspace/verification_20251010_123456.log

========================================
CloudFront 検証
========================================
CloudFront Distribution: E1234ABCD5678
✓ /contents/ パスルーティングが設定されています
✓ CloudFront Distribution が正常にデプロイされています

========================================
Application Load Balancer 検証
========================================
✓ 全てのターゲット (2/2) が正常です

========================================
EC2 インスタンス検証
========================================
インスタンス ID: i-0123456789abcdef0
✓ SSM Agent がオンラインです

...
```

## 実装のポイント

### カラー出力で視認性向上

```bash
# カラー出力設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_success() {
    if [ $? -eq 0 ]; then
        log "${GREEN}✓ $1${NC}"
    else
        log "${RED}✗ $1${NC}"
        return 1
    fi
}
```

成功は緑色、失敗は赤色、警告は黄色で表示されるため、問題箇所が一目でわかります。

### jqでJSON解析

AWS CLIの出力をjqで解析することで、複雑な条件判定も簡潔に記述できます：

```bash
# CloudFront の /contents/ パスルーティング確認
local behaviors=$(echo "$distribution_info" | jq -r '.Distribution.DistributionConfig.CacheBehaviors.Items[]?.PathPattern // empty')
if echo "$behaviors" | grep -q "/contents/*"; then
    log "${GREEN}✓ /contents/ パスルーティングが設定されています${NC}"
fi
```

### ログファイルへの同時出力

`tee` コマンドを使って、コンソールとログファイルの両方に出力します：

```bash
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}
```

## 応用例

### 複数の受講者を一括チェック

複数の受講者のAWS環境を順次チェックする場合、設定ファイルを切り替えながら実行できます：

```bash
for config in config/aws-config-*.sh; do
    echo "検証対象: $config"
    source "$config"
    ./scripts/verify-aws-resources.sh
done
```

### CI/CDパイプラインへの組み込み

GitHub Actionsなどと組み合わせて、インフラ変更のPRに対して自動検証を実行することも可能です：

```yaml
name: AWS Infrastructure Verification

on:
  pull_request:
    paths:
      - 'terraform/**'
      - 'cloudformation/**'

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-northeast-1
      - name: Run Verification
        run: ./scripts/verify-aws-resources.sh
```

## まとめ

このツールを使うことで、以下のメリットが得られます：

✅ **時間削減**: 手動確認が数時間から数分に短縮
✅ **品質向上**: 見落としがなくなり、レビュー品質が向上
✅ **再現性**: 同じ基準で全員を公平に評価できる
✅ **教育効果**: 受講者もセルフチェックに利用できる

AWSインフラのレビューを効率化したい方は、ぜひ参考にしてみてください。

## 参考資料

- [AWS CLI Command Reference](https://docs.aws.amazon.com/cli/)
- [Dev Containers](https://code.visualstudio.com/docs/devcontainers/containers)
- [AWS Well-Architected Framework](https://aws.amazon.com/architecture/well-architected/)