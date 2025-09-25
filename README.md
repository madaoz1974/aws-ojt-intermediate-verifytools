# AWS リソース検証環境

このプロジェクトは、AWS上に構築されたアプリケーション環境のリソースを検証するためのDev Container環境です。

## 概要

以下の成果物確認ポイントに基づいて、AWSリソースの設定を自動検証します：

- **CloudFront**: `/contents/`パスルーティングの設定
- **ALB**: ヘルスチェックの正常性
- **EC2**: 必要なソフトウェアのインストール、IAM Roleの設定
- **Security Group**: 適切な参照設定と0.0.0.0/0アクセスの制限
- **RDS**: カスタムパラメーターグループとDBの存在確認
- **S3**: CloudFront(OAC)とEC2 Roleへのバケットポリシー設定
- **暗号化**: EBS/RDS/S3の暗号化設定
- **正常性確認**: CloudFrontドメインでのTomcat動作確認

## 前提条件

- VS Code + Dev Containers拡張機能
- Docker Desktop
- AWS CLIの認証情報（`~/.aws/`）

## セットアップ手順

### 1. Dev Container環境の起動

```bash
# VS Codeでプロジェクトを開く
code .

# Command Palette (Cmd+Shift+P / Ctrl+Shift+P) を開く
# "Dev Containers: Reopen in Container" を選択
```

### 2. AWS認証情報の設定

Dev Container起動後、AWS CLIの設定を確認・設定します：

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
# または
nano config/aws-config.sh
```

#### 設定項目の例：

```bash
# CloudFront
CLOUDFRONT_DISTRIBUTION_ID="E1234567890123"
CLOUDFRONT_DOMAIN="d1234567890123.cloudfront.net"

# ALB
ALB_ARN="arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:loadbalancer/app/my-alb/1234567890123456"

# RDS
RDS_INSTANCE_ID="rds-tomcat"
RDS_PASSWORD="your-password"

# S3
S3_BUCKET_NAME="my-tomcat-app-bucket"
```

## 使用方法

### 基本的な検証実行

```bash
# 全ての検証を実行
./scripts/verify-aws-resources.sh
```

### 検証結果の確認

検証結果は以下の場所に出力されます：

- **コンソール出力**: リアルタイムで結果を表示
- **ログファイル**: `/workspace/verification_YYYYMMDD_HHMMSS.log`

#### 結果の例：

```
========================================
CloudFront 検証
========================================
CloudFront Distribution: E1234567890123
Default Root Object: index.html
✓ /contents/ パスルーティングが設定されています
✓ CloudFront Distribution が正常にデプロイされています

========================================
Application Load Balancer 検証
========================================
ALB ARN: arn:aws:elasticloadbalancing:...
Target Group: arn:aws:elasticloadbalancing:...
  Health Check Path: /
  Health Check Port: 8080
  Health Check Protocol: HTTP
✓ 全てのターゲット (2/2) が正常です
```

## 検証項目詳細

### 1. CloudFront検証
- Distribution の存在確認
- `/contents/` パスルーティング設定の確認
- デプロイ状態の確認

### 2. ALB検証
- Load Balancer の存在確認
- Target Group の設定確認
- ヘルスチェックの正常性確認

### 3. EC2検証
- インスタンスの実行状態確認
- IAM Instance Profile の設定確認
- Security Group の設定確認
- SSM Agent の状態確認

### 4. Security Group検証
- 0.0.0.0/0 からの直接アクセス制限
- Security Group 参照の設定確認

### 5. RDS検証
- インスタンスの存在確認
- パラメーターグループの確認（デフォルト以外）
- ストレージ暗号化の確認
- データベース接続テスト
- `movie` データベースの存在確認

### 6. S3検証
- バケットの存在確認
- 暗号化設定の確認
- バケットポリシーの確認（CloudFront OAC、EC2 Role）

### 7. 暗号化検証
- EBS ボリュームの暗号化確認
- RDS ストレージの暗号化確認
- S3 バケットの暗号化確認

### 8. アプリケーション正常性確認
- CloudFront ドメインへのHTTPS接続テスト
- Tomcat アプリケーションの動作確認

## トラブルシューティング

### よくある問題と対処法

#### 1. AWS認証エラー
```
✗ AWS CLI が設定されていません。aws configure を実行してください。
```

**対処法:**
```bash
aws configure
# AWS Access Key ID、Secret Access Key、Region、Output format を入力
```

#### 2. リソースが見つからない
```
✗ CloudFront Distribution が見つかりません
```

**対処法:**
- `config/aws-config.sh` の設定値を確認
- AWSコンソールで実際のリソースIDを確認
- 適切なリージョンが設定されているか確認

#### 3. RDS接続エラー
```
✗ データベースに接続できません
```

**対処法:**
- RDS_PASSWORD が正しく設定されているか確認
- Security Group でPostgreSQLポート(5432)が開放されているか確認
- RDS インスタンスが実行中であることを確認

#### 4. 権限不足エラー

**対処法:**
- IAM ユーザーまたはロールに以下の権限があることを確認：
  - CloudFront: `cloudfront:GetDistribution`
  - ELB: `elasticloadbalancing:DescribeLoadBalancers`, `elasticloadbalancing:DescribeTargetGroups`
  - EC2: `ec2:DescribeInstances`, `ec2:DescribeSecurityGroups`, `ec2:DescribeVolumes`
  - RDS: `rds:DescribeDBInstances`
  - S3: `s3:GetBucketPolicy`, `s3:GetBucketEncryption`
  - IAM: `iam:ListAttachedRolePolicies`
  - SSM: `ssm:DescribeInstanceInformation`

## EC2内でのバージョン確認

EC2インスタンス内で以下のコマンドを実行して、ソフトウェアのバージョンを確認してください：

```bash
# EC2インスタンスにSSH/Session Manager で接続後

# Java バージョン確認
java -version

# Gradle バージョン確認
gradle -v

# Tomcat バージョン確認
/opt/tomcat/bin/version.sh

# Git バージョン確認
git --version

# Maven バージョン確認
mvn --version

# PostgreSQL クライアント確認
psql -h YOUR_RDS_ENDPOINT -U postgres -d movie -p 5432
```

## 環境の構成

```
.
├── .devcontainer/
│   ├── devcontainer.json    # Dev Container設定
│   └── Dockerfile          # コンテナイメージ定義
├── config/
│   └── aws-config.template.sh  # 設定ファイルテンプレート
├── scripts/
│   ├── setup.sh            # セットアップスクリプト
│   └── verify-aws-resources.sh  # 検証メインスクリプト
├── .gitignore
└── README.md
```

## セキュリティ注意事項

- `config/aws-config.sh` にはRDSパスワードなどの機密情報が含まれる可能性があります
- このファイルは `.gitignore` に含まれており、Gitに追跡されません
- 本番環境では環境変数やAWS Secrets Managerの使用を検討してください

## 参考情報

- [CloudFront パスベースルーティング](https://docs.aws.amazon.com/ja_jp/AmazonCloudFront/latest/DeveloperGuide/distribution-web-values-specify.html)
- [ALB ヘルスチェック](https://docs.aws.amazon.com/ja_jp/elasticloadbalancing/latest/application/target-group-health-checks.html)
- [RDS パラメーターグループ](https://docs.aws.amazon.com/ja_jp/AmazonRDS/latest/UserGuide/USER_WorkingWithDBInstanceParamGroups.html)
- [AWS暗号化設定](https://www.sunnycloud.jp/column/20211025-01/)

## ライセンス

このプロジェクトはMITライセンスの下で公開されています。