# AWS リソース削除対象リスト（2025年12月2日）

カリキュラム完了に伴い、削除予定のAWSリソースの詳細リストです。

---

## 削除対象リソース総括

| カテゴリ | リソースタイプ | 数量 | 削除予定 |
|---|---|---|---|
| **計算** | EC2 インスタンス | 1個 | ✓ |
| | Elastic IP | 2個 | ✓ |
| **ストレージ** | S3 バケット | 複数 | ✓ |
| | EBS スナップショット | 23個 | ✓ |
| **データベース** | RDS インスタンス | 1個 | ✓ |
| | RDS スナップショット | 複数 | ✓ |
| **ネットワーク** | CloudFront Distribution | 3個 | ✓ |
| **監視・ログ** | CloudWatch Alarms | 2個 | ✓ |
| | CloudWatch Log Groups | 11個 | ✓ |
| | CloudTrail | 1個 | ✓ |
| **自動化** | Lambda 関数 | 0個 (確認時) | ✓ |
| | CodePipeline | 0個 (確認時) | ✓ |
| **アクセス管理** | IAM グループ | 14個 | ✓ |

---

## 詳細削除対象リスト

### 1. EC2 インスタンス（1個）
```
ID              InstanceType   State      Name
i-05d8875ab3f368f93  t3.medium      running    (name tag なし)
```

### 2. Elastic IP（2個）
```
eipalloc-0d17f777c875e5b18
eipalloc-0e9d2ee405527e703
```

### 3. EBS スナップショット（23個）
```
snap-032106cf4e510fedc  snap-06293435a97c1c913  snap-05dbe5b11f46fb7d1
snap-0e21cdc05304e4cc9  snap-03fde3af29052500d  snap-0a6d55a9f64fa3ee4
snap-0eb839e8e92e1c214  snap-068f0be9a2f019910  snap-0e10c86c4b7434dd8
snap-0b7af2bcb9fe8a3b9  snap-0e886a23c2d15e276  snap-0a5dcc99cf59ca588
snap-0c823984c4d1f6a66  snap-0d3b442279ed0049b  snap-0642ce155ed7aa0c7
snap-045b74e37f6444c62  snap-09a4c404df147f2d6  snap-0e01af87f3ec88569
snap-091ffa4c21ee04031  snap-0311dfce3c009b548  snap-06b3354a12a643049
snap-06d62b2726972e131  snap-0666ecd1dc8244634  snap-05653a34fabfd8c35
```

### 4. RDS インスタンス（1個）
```
DBInstanceIdentifier: vs-dev-rds-app-2
Engine: PostgreSQL
Status: available (または他の状態)
```

### 5. CloudFront Distribution（3個）
```
E200GHGHOH67RA  (Status: Deployed/InProgress)
E3LKNA63UJUSGM  (Status: Deployed/InProgress)
E3EU318JQBFG81  (Status: Deployed/InProgress)
```

### 6. S3 バケット（複数個）
- 各バケット内のオブジェクトも削除対象

### 7. CloudWatch Alarms（2個）
```
AWS Resource Error(CloudTrail)
ec2-sato-alarm
```

### 8. CloudWatch Log Groups（11個）
```
/aws/lambda/lambda-sato-alblog
/aws/lambda/lambda-sato-cloudtrail
/aws/lambda/lambda-sato-start-ec2
/aws/lambda/lambda-sato-stop-ec2
/aws/rds/instance/rds-sato-video/postgresql
RDSOSMetrics
logg-sato-alb
logg-sato-catalina.out
logg-sato-ec2start
logg-sato-ec2stop
logg_sato_video
```

### 9. CloudTrail（1個）
```
Name: vs-dev-ct-app
S3 Bucket: vs-dev-s3-app
```

### 10. IAM グループ（14個）
```
1. dev-iam-accounting-murayama
2. dev-iam-executive-murayama
3. dev-iam-it-murayama
4. iamgroup-sato-finance-costonly
5. iamgroup-sato-it-nocost-noiam
6. iamgroup-sato-management-admin
7. Mentor
8. movie-dev-iamgroup-CustomerAccountingGroup-ito-01
9. movie-dev-iamgroup-CustomerITGroup-ito-01
10. movie-dev-iamgroup-CustomerManagementGroup-ito-01
11. Students
12. vs-dev-iam-group_accounting
13. vs-dev-iam-group_accounting_admin
14. vs-dev-iam-group_accounting_admin
15. vs-dev-iam-it
```

---

## 削除実行手順

### ステップ 1: ドライランで確認（推奨）

```bash
cd /workspaces/aws-ojt-intermediate-verifytools
bash cleanup-aws-resources.sh --dry-run
```

**出力例:**
```
[DRY-RUN] EC2 インスタンス 削除: i-05d8875ab3f368f93
  実行コマンド: aws ec2 terminate-instances --instance-ids "i-05d8875ab3f368f93" --region ap-northeast-1
```

### ステップ 2: 実際の削除実行

```bash
bash cleanup-aws-resources.sh --execute
```

**確認プロンプト:**
```
[⚠] リソース削除を開始します。この操作は元に戻せません。
本当に実行しますか？ (yes/no):
```

`yes` を入力して確認します。

### ステップ 3: 削除の進行状況監視

スクリプト実行中は以下のようなログが表示されます：

```
[実行] CloudFront Distribution 無効化・削除: E3EU318JQBFG81
[INFO] Distribution 削除待機中（最大3分）...
[✓] CloudFront 削除完了: E3EU318JQBFG81
```

### ステップ 4: 削除完了確認

スクリプト完了後、以下のコマンドで確認：

```bash
# EC2 確認（何も表示されなければ完了）
aws ec2 describe-instances --region ap-northeast-1 --filters 'Name=instance-state-name,Values=running,stopped'

# RDS 確認
aws rds describe-db-instances --region ap-northeast-1

# S3 確認
aws s3 ls

# CloudFront 確認
aws cloudfront list-distributions
```

---

## 重要な注意事項

### ⚠️ 削除前の最終確認

1. **バックアップ確認**
   - RDS: 最終スナップショットが作成済みか確認
   - EC2: 必要なデータが保存済みか確認
   - S3: 重要なファイルが別の場所に保存済みか確認

2. **他のリソースへの影響**
   - CloudFront が削除されると URL が無効化
   - EC2 削除後、接続不可
   - RDS 削除後、データベース復旧不可

3. **コスト削減効果**
   - EC2 インスタンス停止: 月額 ~¥3,000-5,000 削減
   - RDS インスタンス停止: 月額 ~¥5,000-8,000 削減
   - EBS スナップショット削除: 月額 ~¥1,000-2,000 削減
   - **合計削減: 月額 ~¥10,000-15,000相当**

### 削除順序の重要性

以下の順序で削除してください（スクリプトが自動管理）：

```
1. CI/CD (CodePipeline, Lambda)
2. CloudFront
3. ロードバランサー
4. EC2 インスタンス
5. EBS スナップショット
6. RDS インスタンス
7. S3 バケット
8. CloudWatch/CloudTrail
9. IAM グループ
```

---

## トラブルシューティング

### Q: CloudFront の削除に失敗する

**原因:** Distribution がまだ有効な状態

**対処:**
```bash
# Distribution を無効化してから削除
aws cloudfront get-distribution --id E3EU318JQBFG81
# 設定を取得して Enabled: false に変更
# 数分待機してから削除
```

### Q: S3 バケット削除に失敗する

**原因:** バケット内にオブジェクトが残っている

**対処:**
```bash
aws s3 rm s3://bucket-name --recursive
aws s3 rb s3://bucket-name --force
```

### Q: IAM グループ削除に失敗する

**原因:** グループにメンバーまたはポリシーが割り当てられている

**対処:**
```bash
# メンバー削除
aws iam get-group --group-name <GROUP_NAME> --query 'Users[*].UserName' --output text | \
  while read user; do
    aws iam remove-user-from-group --group-name <GROUP_NAME> --user-name "$user"
  done

# ポリシー削除
aws iam list-attached-group-policies --group-name <GROUP_NAME> --query 'AttachedPolicies[*].PolicyArn' --output text | \
  while read policy_arn; do
    aws iam detach-group-policy --group-name <GROUP_NAME> --policy-arn "$policy_arn"
  done

# グループ削除
aws iam delete-group --group-name <GROUP_NAME>
```

---

## 参考資料

- [CLEANUP_GUIDE.md](CLEANUP_GUIDE.md) - 詳細な手動削除ガイド
- [cleanup-aws-resources.sh](cleanup-aws-resources.sh) - 自動削除スクリプト

---

**最終更新:** 2025年12月2日
**削除実行者:** ここに実行者名を記入
**実行日時:** ___________________
**完了確認:** ___________________
