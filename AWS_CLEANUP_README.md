# AWS カリキュラム完了後のリソース削除ガイド

**実行日:** 2025年12月2日  
**用途:** AWS OJT 中間レベルコース終了後のリソース削除

---

## 📋 概要

このガイドは、AWS OJT 中間レベルコースの完了に伴い、構築されたすべてのAWSリソースを安全かつ確実に削除するためのものです。

**検出されたリソース数:**
- EC2 インスタンス: 1個
- RDS インスタンス: 1個
- EBS スナップショット: 23個
- CloudFront Distribution: 3個
- S3 バケット: 複数個
- CloudWatch ログ: 11個
- IAM グループ: 14個
- その他: CloudTrail、アラーム、Lambda など

---

## ⚡ クイックスタート

### 最速削除手順（5分以内）

```bash
# 1. ドライランで削除対象を確認
cd /workspaces/aws-ojt-intermediate-verifytools
bash cleanup-aws-resources.sh --dry-run

# 2. 削除内容に問題がなければ実行
bash cleanup-aws-resources.sh --execute

# 3. 確認メッセージで "yes" と入力
yes
```

**完了！** スクリプトが自動で全リソースを削除します。

---

## 📁 提供ファイル

このディレクトリには以下の削除用ファイルが含まれています：

### 1. **cleanup-aws-resources.sh** ← 推奨：自動削除スクリプト
   - 依存関係を考慮した安全な削除順序
   - ドライランモード対応
   - 詳細なログ出力
   - CloudFront の無効化・削除待機に対応

### 2. **CLEANUP_GUIDE.md** ← 参考：詳細な手動削除ガイド
   - リソースごとの詳細な削除コマンド
   - トラブルシューティング
   - 手動で削除する場合の手順

### 3. **DELETION_TARGETS.md** ← 参照：削除対象リスト
   - 削除予定のリソース詳細
   - リソースID一覧
   - 削除進行中の確認方法

---

## 🚀 実行手順

### Step 1: ドライランで確認（必須）

```bash
bash cleanup-aws-resources.sh --dry-run
```

**確認項目:**
- [ ] 削除対象リソースの数が期待通りか
- [ ] 予期しないリソースが含まれていないか
- [ ] エラーメッセージがないか

**出力例:**
```
[DRY-RUN] EC2 インスタンス 削除: i-05d8875ab3f368f93
[DRY-RUN] EBS スナップショット 削除: snap-032106cf4e510fedc
...
[INFO] ドライランモード: 削除は実行されませんでした。
```

### Step 2: 実行前の最終確認

削除前に以下を確認してください：

- [ ] 重要なデータはバックアップ済みか
- [ ] RDS の最終スナップショットが作成されるか確認したか
- [ ] 他のプロジェクトで使用中のリソースがないか
- [ ] AWS コンソールでビジュアル的に確認したか

### Step 3: 実際の削除を実行

```bash
bash cleanup-aws-resources.sh --execute
```

**確認プロンプト:**
```
[⚠] リソース削除を開始します。この操作は元に戻せません。
本当に実行しますか？ (yes/no):
```

`yes` と入力します。（`no` の場合はキャンセル）

**実行中の出力:**
```
[実行] EC2 インスタンス 削除: i-05d8875ab3f368f93
[実行] EBS スナップショット 削除: snap-032106cf4e510fedc
...
[✓] CloudFront 削除完了: E3EU318JQBFG81
```

### Step 4: 削除の進行を監視

**CloudFront の削除に時間がかかる場合:**
- CloudFront Distribution の無効化: 1-2分
- 削除までの待機: 最大3分
- 合計: 最大5分

**その他のリソースの削除:**
- ほぼ即座に削除されます
- ただし、EC2 削除後の状態更新に1-2分

### Step 5: 削除完了確認

スクリプト実行完了後、以下で確認：

```bash
# EC2 確認
aws ec2 describe-instances --region ap-northeast-1 \
  --filters "Name=instance-state-name,Values=running,stopped"
# → 結果が空なら OK

# RDS 確認
aws rds describe-db-instances --region ap-northeast-1
# → 結果が空なら OK

# S3 確認
aws s3 ls
# → 結果が空なら OK

# CloudFront 確認
aws cloudfront list-distributions
# → Items が空なら OK
```

---

## 🔍 削除順序（スクリプトが自動管理）

スクリプトは以下の順序で安全に削除します：

```
1️⃣  CodePipeline (CI/CD 依存)
2️⃣  Lambda 関数 (イベント依存)
3️⃣  CloudFront Distribution (複数待機対応)
4️⃣  ロードバランサー
5️⃣  EC2 インスタンス
6️⃣  Elastic IP
7️⃣  EBS スナップショット
8️⃣  RDS インスタンス
9️⃣  RDS スナップショット
🔟 S3 バケット
1️⃣1️⃣ CloudWatch Alarms
1️⃣2️⃣ CloudWatch Log Groups
1️⃣3️⃣ CloudTrail
1️⃣4️⃣ IAM グループ
```

---

## 💰 予想コスト削減効果

削除後の月額コスト削減効果：

| リソース | 月額削減 | 備考 |
|---|---|---|
| EC2 (t3.medium) | ¥3,000-5,000 | 使用中 |
| RDS (PostgreSQL) | ¥5,000-8,000 | db.t3.micro |
| EBS スナップショット (23個) | ¥1,000-2,000 | ストレージ料金 |
| CloudFront | ¥500-1,000 | データ転送料金 |
| S3 | ¥100-500 | ストレージ料金 |
| CloudWatch | ¥100-300 | ログ保存料金 |
| **合計削減** | **¥10,000-17,000** | **月額** |

---

## ⚠️ 重要な注意事項

### 削除後は復旧できません

```
⛔ 削除されたリソースは復旧できません
⛔ スナップショットも一緒に削除されます
⛔ データベースも復旧できません
```

### バックアップ確認チェックリスト

- [ ] RDS の重要なデータは取得済みか
- [ ] S3 の重要なファイルは別の場所に保存済みか
- [ ] EC2 インスタンスのデータは保存済みか
- [ ] CloudWatch ログは必要な場合は保存済みか

---

## 🔧 手動での削除方法

自動スクリプトが使用できない場合、手動で削除できます：

```bash
# 詳細なコマンドは CLEANUP_GUIDE.md を参照
# 以下は例です：

# EC2 削除
aws ec2 terminate-instances --instance-ids i-05d8875ab3f368f93 --region ap-northeast-1

# RDS 削除
aws rds delete-db-instance --db-instance-identifier vs-dev-rds-app-2 \
  --skip-final-snapshot --region ap-northeast-1

# S3 削除
aws s3 rm s3://bucket-name --recursive
aws s3 rb s3://bucket-name
```

詳細は [CLEANUP_GUIDE.md](CLEANUP_GUIDE.md) を参照してください。

---

## 🆘 トラブルシューティング

### スクリプトが失敗する場合

**1. AWS CLI が設定されているか確認**
```bash
aws sts get-caller-identity
```

**2. IAM 権限が十分か確認**
```bash
# 削除には以下の権限が必要
ec2:TerminateInstances
rds:DeleteDBInstance
s3:DeleteBucket
cloudfront:DeleteDistribution
lambda:DeleteFunction
iam:DeleteGroup
```

**3. エラーメッセージを確認**
```bash
# ドライランで詳細なエラーを確認
bash cleanup-aws-resources.sh --dry-run 2>&1 | grep "ERROR\|error"
```

### 特定のリソースが削除できない場合

[CLEANUP_GUIDE.md](CLEANUP_GUIDE.md) の「トラブルシューティング」セクションを参照してください。

---

## 📊 削除完了レポート

削除実行後、以下をメモしてください：

```
削除実行日時: ___________________
実行ユーザー: ___________________

削除完了リソース:
- [ ] EC2 インスタンス
- [ ] RDS インスタンス
- [ ] S3 バケット
- [ ] CloudFront Distribution
- [ ] EBS スナップショット
- [ ] CloudWatch ログ
- [ ] IAM グループ
- [ ] CloudTrail
- [ ] Lambda 関数

検証完了日: ___________________
検証ユーザー: ___________________
```

---

## 📚 参考資料

| ドキュメント | 用途 |
|---|---|
| [CLEANUP_GUIDE.md](CLEANUP_GUIDE.md) | 手動削除の詳細手順 |
| [DELETION_TARGETS.md](DELETION_TARGETS.md) | 削除対象リソースの詳細リスト |
| [cleanup-aws-resources.sh](cleanup-aws-resources.sh) | 自動削除スクリプト |

---

## ✅ 削除後のチェックリスト

削除完了後、以下を確認してください：

- [ ] AWS コンソールで EC2 が表示されていない
- [ ] AWS コンソールで RDS が表示されていない
- [ ] AWS コンソールで S3 バケット一覧が空
- [ ] AWS コンソールで CloudFront が表示されていない
- [ ] AWS コスト計算ツールで月額予測が減少している
- [ ] CloudWatch アラーム通知がないことを確認

---

## 📞 サポート

削除中に問題が発生した場合：

1. **ドライランで詳細を確認**
   ```bash
   bash cleanup-aws-resources.sh --dry-run 2>&1 > debug.log
   ```

2. **AWS コンソールで確認**
   - リソースの依存関係を確認
   - 削除中のリソースの状態確認

3. **手動削除の実施**
   - [CLEANUP_GUIDE.md](CLEANUP_GUIDE.md) の該当セクションを参照
   - 個別のコマンドで削除

---

**作成日:** 2025年12月2日  
**最終更新:** 2025年12月2日  
**ステータス:** 実行準備完了 ✓
