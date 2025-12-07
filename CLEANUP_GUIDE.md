# AWS リソース削除ガイド

カリキュラム完了に伴い、残されているAWSリソースを削除するための詳細ガイドです。

**⚠️ 注意: このガイドに従って削除したリソースは復旧できません。実行前に必ずバックアップを確認してください。**

---

## 概要

検出されたリソース一覧（2025年12月2日時点）:

| リソースタイプ | 数量 | 状態 |
|---|---|---|
| EC2 インスタンス | 1個 | 実行中 |
| RDS インスタンス | 1個 | 使用中 |
| S3 バケット | 複数 | 使用中 |
| CloudFront Distribution | 1個 | デプロイ済み |
| EBS スナップショット | 複数 | 保存済み |
| RDS スナップショット | 複数 | 保存済み |
| Lambda 関数 | 4個 | 設定済み |
| CloudWatch Alarms | 2個 | 設定済み |
| CloudWatch Log Groups | 11個 | 作成済み |
| AWS Backup プラン | 3個 | 有効 |
| EventBridge ルール | 4個 | 有効 |
| CloudTrail | 1個 | 停止中 |
| CodePipeline | 1個 | 構築済み |
| IAM グループ | 14個 | 作成済み |

---

## 削除順序（重要）

**リソースには依存関係があるため、以下の順序で削除してください：**

```
1. CodePipeline (CI/CD)
   ↓
2. Lambda 関数
   ↓
3. CloudFront Distribution
   ↓
4. ロードバランサー (ALB)
   ↓
5. EC2 インスタンス
   ↓
6. Elastic IP
   ↓
7. EBS スナップショット
   ↓
8. RDS インスタンス
   ↓
9. RDS スナップショット
   ↓
10. S3 バケット
    ↓
11. CloudWatch リソース
    ↓
12. AWS Backup
    ↓
13. EventBridge
    ↓
14. CloudTrail
    ↓
15. IAM リソース
```

---

## 詳細な削除手順

### 1. CodePipeline の削除

```bash
# パイプライン名確認
aws codepipeline list-pipelines --region ap-northeast-1

# パイプライン削除
aws codepipeline delete-pipeline --name vs-dev-codepipeline-app --region ap-northeast-1

# 確認
aws codepipeline list-pipelines --region ap-northeast-1
```

**関連リソース:**
- CodeBuild プロジェクト（自動削除されない）
- CodeDeploy アプリケーション（自動削除されない）

```bash
# CodeBuild プロジェクト確認
aws codebuild list-projects --region ap-northeast-1

# 必要に応じて削除
# aws codebuild delete-project --name <project-name> --region ap-northeast-1
```

---

### 2. Lambda 関数の削除

検出された Lambda 関数:
- `lambda-sato-alblog`
- `lambda-sato-cloudtrail`
- `lambda-sato-start-ec2`
- `lambda-sato-stop-ec2`

```bash
# Lambda 関数一覧確認
aws lambda list-functions --region ap-northeast-1 --query 'Functions[*].FunctionName' --output text

# 各関数を削除
aws lambda delete-function --function-name lambda-sato-alblog --region ap-northeast-1
aws lambda delete-function --function-name lambda-sato-cloudtrail --region ap-northeast-1
aws lambda delete-function --function-name lambda-sato-start-ec2 --region ap-northeast-1
aws lambda delete-function --function-name lambda-sato-stop-ec2 --region ap-northeast-1

# 確認
aws lambda list-functions --region ap-northeast-1
```

---

### 3. CloudFront Distribution の削除

検出された Distribution:
- ID: `E3EU318JQBFG81`

**注意: Distribution を削除する前に DISABLED (無効化) する必要があります**

```bash
# Distribution 情報取得
aws cloudfront get-distribution --id E3EU318JQBFG81

# Distribution 無効化（ETag が必要）
ETAG=$(aws cloudfront get-distribution --id E3EU318JQBFG81 --query 'ETag' --output text)
aws cloudfront get-distribution-config --id E3EU318JQBFG81 > /tmp/cf-config.json

# JSON ファイルを編集して "Enabled": false に変更
sed -i 's/"Enabled": true/"Enabled": false/g' /tmp/cf-config.json

# 更新
aws cloudfront update-distribution --id E3EU318JQBFG81 --distribution-config file:///tmp/cf-config.json --if-match $ETAG

# ⏳ Distribution の無効化完了を待機（5-15分）
echo "Distribution の無効化待機中..."
sleep 60

# 無効化が完了したら削除
ETAG=$(aws cloudfront get-distribution --id E3EU318JQBFG81 --query 'ETag' --output text)
aws cloudfront delete-distribution --id E3EU318JQBFG81 --if-match $ETAG

# 確認
aws cloudfront list-distributions --query 'DistributionList.Items[*].Id' --output text
```

**代替方法（AWS コンソール使用）:**
1. CloudFront コンソール → Distributions
2. 該当 Distribution 選択 → Disable
3. 完了後 → Delete

---

### 4. ロードバランサー (ALB) の削除

```bash
# ALB 一覧確認（名前で検索）
aws elbv2 describe-load-balancers --region ap-northeast-1 --query 'LoadBalancers[*].[LoadBalancerArn,LoadBalancerName]' --output table

# Target Group も一緒に取得
aws elbv2 describe-target-groups --region ap-northeast-1 --query 'TargetGroups[*].[TargetGroupArn,TargetGroupName]' --output table

# ALB ARN を使用して削除
aws elbv2 delete-load-balancer --load-balancer-arn <ALB_ARN> --region ap-northeast-1

# Target Group は自動削除されない場合あり
aws elbv2 delete-target-group --target-group-arn <TARGET_GROUP_ARN> --region ap-northeast-1

# リスナーが残っていないか確認
aws elbv2 describe-listeners --load-balancer-arn <ALB_ARN> --region ap-northeast-1 2>/dev/null || echo "ALB 削除完了"
```

---

### 5. EC2 インスタンスの削除

検出されたインスタンス:
- ID: `i-05d8875ab3f368f93`
- Type: `t3.medium`

```bash
# インスタンス一覧確認
aws ec2 describe-instances --region ap-northeast-1 --filters "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' --output table

# インスタンス停止（オプション、削除時に停止状態でなくても OK）
aws ec2 stop-instances --instance-ids i-05d8875ab3f368f93 --region ap-northeast-1

# ⏳ 停止完了待機
aws ec2 wait instance-stopped --instance-ids i-05d8875ab3f368f93 --region ap-northeast-1

# インスタンス削除
aws ec2 terminate-instances --instance-ids i-05d8875ab3f368f93 --region ap-northeast-1

# ⏳ 削除完了待機
aws ec2 wait instance-terminated --instance-ids i-05d8875ab3f368f93 --region ap-northeast-1

# 確認
aws ec2 describe-instances --instance-ids i-05d8875ab3f368f93 --region ap-northeast-1 --query 'Reservations[*].Instances[*].State.Name'
```

---

### 6. Elastic IP の削除

```bash
# Elastic IP 一覧確認
aws ec2 describe-addresses --region ap-northeast-1 --query 'Addresses[*].[PublicIp,AllocationId,AssociationId]' --output table

# Elastic IP 割り当て解除（Association がある場合）
aws ec2 disassociate-address --association-id <ASSOCIATION_ID> --region ap-northeast-1

# Elastic IP 削除
aws ec2 release-address --allocation-id <ALLOCATION_ID> --region ap-northeast-1

# 確認
aws ec2 describe-addresses --region ap-northeast-1 --query 'Addresses[].AllocationId' --output text
```

---

### 7. EBS スナップショットの削除

```bash
# EBS スナップショット一覧確認
aws ec2 describe-snapshots --region ap-northeast-1 --owner-ids self \
  --query 'Snapshots[*].[SnapshotId,State,VolumeSize,StartTime,Description]' --output table

# 各スナップショット削除
aws ec2 delete-snapshot --snapshot-id <SNAPSHOT_ID> --region ap-northeast-1

# 複数削除スクリプト
for snapshot_id in $(aws ec2 describe-snapshots --region ap-northeast-1 --owner-ids self --query 'Snapshots[*].SnapshotId' --output text); do
  echo "Deleting snapshot: $snapshot_id"
  aws ec2 delete-snapshot --snapshot-id $snapshot_id --region ap-northeast-1
done

# 確認
aws ec2 describe-snapshots --region ap-northeast-1 --owner-ids self --query 'Snapshots[*].SnapshotId' --output text
```

---

### 8. RDS インスタンスの削除

検出された RDS インスタンス:
- Identifier: `vs-dev-rds-app-2`
- Engine: PostgreSQL

**注意: 削除前に最終スナップショットを作成するか確認してください**

```bash
# RDS インスタンス一覧確認
aws rds describe-db-instances --region ap-northeast-1 \
  --query 'DBInstances[*].[DBInstanceIdentifier,Engine,DBInstanceStatus]' --output table

# RDS インスタンス削除（最終スナップショットなし）
aws rds delete-db-instance --db-instance-identifier vs-dev-rds-app-2 \
  --skip-final-snapshot --region ap-northeast-1

# または、最終スナップショット作成あり
# aws rds delete-db-instance --db-instance-identifier vs-dev-rds-app-2 \
#   --final-db-snapshot-identifier vs-dev-rds-app-2-final-snapshot --region ap-northeast-1

# ⏳ 削除完了待機（3-5分）
echo "RDS インスタンス削除中..."
sleep 30

# 確認
aws rds describe-db-instances --region ap-northeast-1 --query 'DBInstances[*].DBInstanceIdentifier' --output text
```

---

### 9. RDS スナップショットの削除

```bash
# RDS スナップショット一覧確認
aws rds describe-db-snapshots --region ap-northeast-1 \
  --query 'DBSnapshots[*].[DBSnapshotIdentifier,DBInstanceIdentifier,Status,SnapshotCreateTime]' --output table

# 各スナップショット削除
aws rds delete-db-snapshot --db-snapshot-identifier <SNAPSHOT_ID> --region ap-northeast-1

# 複数削除スクリプト
for snapshot_id in $(aws rds describe-db-snapshots --region ap-northeast-1 --query 'DBSnapshots[*].DBSnapshotIdentifier' --output text); do
  echo "Deleting RDS snapshot: $snapshot_id"
  aws rds delete-db-snapshot --db-snapshot-identifier $snapshot_id --region ap-northeast-1
done

# 確認
aws rds describe-db-snapshots --region ap-northeast-1 --query 'DBSnapshots[*].DBSnapshotIdentifier' --output text
```

---

### 10. S3 バケットの削除

検出された S3 バケット:
- `vs-dev-s3-app` (App用)
- `vs-dev-s3-lp` (LP用)
- その他

**注意: S3 バケットは空にしてから削除する必要があります**

```bash
# S3 バケット一覧確認
aws s3 ls

# バケット内のファイル確認
aws s3 ls s3://vs-dev-s3-app --recursive

# バケット内のファイルをすべて削除
aws s3 rm s3://vs-dev-s3-app --recursive

# バージョニング有効時はバージョン管理対象も削除
aws s3api list-object-versions --bucket vs-dev-s3-app --query 'Versions[*].[Key,VersionId]' --output text | \
  while read key version; do
    aws s3api delete-object --bucket vs-dev-s3-app --key "$key" --version-id "$version"
  done

# バケット削除マーカー削除
aws s3api list-object-versions --bucket vs-dev-s3-app --query 'DeleteMarkers[*].[Key,VersionId]' --output text | \
  while read key version; do
    aws s3api delete-object --bucket vs-dev-s3-app --key "$key" --version-id "$version"
  done

# バケット削除
aws s3 rb s3://vs-dev-s3-app

# 複数バケット削除スクリプト
for bucket in $(aws s3 ls | awk '{print $3}'); do
  echo "Processing bucket: $bucket"
  aws s3 rm s3://$bucket --recursive --quiet
  aws s3 rb s3://$bucket --force
done

# 確認
aws s3 ls
```

---

### 11. CloudWatch リソースの削除

#### CloudWatch Alarms

```bash
# アラーム一覧確認
aws cloudwatch describe-alarms --region ap-northeast-1 \
  --query 'MetricAlarms[*].[AlarmName,StateValue]' --output table

# 各アラーム削除
aws cloudwatch delete-alarms --alarm-names <ALARM_NAME> --region ap-northeast-1

# 複数削除スクリプト
for alarm in $(aws cloudwatch describe-alarms --region ap-northeast-1 --query 'MetricAlarms[*].AlarmName' --output text); do
  echo "Deleting alarm: $alarm"
  aws cloudwatch delete-alarms --alarm-names "$alarm" --region ap-northeast-1
done

# 確認
aws cloudwatch describe-alarms --region ap-northeast-1 --query 'MetricAlarms[*].AlarmName' --output text
```

#### CloudWatch Log Groups

```bash
# Log Groups 一覧確認
aws logs describe-log-groups --region ap-northeast-1 --query 'logGroups[*].logGroupName' --output text

# 各 Log Group 削除
aws logs delete-log-group --log-group-name /aws/lambda/lambda-sato-alblog --region ap-northeast-1

# 複数削除スクリプト
for log_group in $(aws logs describe-log-groups --region ap-northeast-1 --query 'logGroups[*].logGroupName' --output text); do
  echo "Deleting log group: $log_group"
  aws logs delete-log-group --log-group-name "$log_group" --region ap-northeast-1
done

# 確認
aws logs describe-log-groups --region ap-northeast-1 --query 'logGroups[*].logGroupName' --output text
```

#### CloudWatch Dashboards

```bash
# ダッシュボード一覧確認
aws cloudwatch list-dashboards --region ap-northeast-1 --query 'DashboardEntries[*].DashboardName' --output text

# ダッシュボード削除
aws cloudwatch delete-dashboards --dashboard-names movie_dev_app_dashboard_ito_01 --region ap-northeast-1

# 確認
aws cloudwatch list-dashboards --region ap-northeast-1
```

---

### 12. AWS Backup リソースの削除

検出された Backup プラン:
- `bp-sato-video`
- `vs-dev-buckup-app`
- `movie-dev-app-ec2backupplan-ito-01`

```bash
# Backup プラン一覧確認
aws backup list-backup-plans --region ap-northeast-1 --query 'BackupPlansList[*].[BackupPlanName,BackupPlanId]' --output table

# Backup プラン削除
aws backup delete-backup-plan --backup-plan-id <BACKUP_PLAN_ID> --region ap-northeast-1

# 復旧ポイント削除
aws backup list-recovery-points-by-backup-vault --backup-vault-name <VAULT_NAME> --region ap-northeast-1

# 復旧ポイント削除
aws backup delete-recovery-point --backup-vault-name <VAULT_NAME> --recovery-point-arn <RECOVERY_POINT_ARN> --region ap-northeast-1

# Backup Vault 削除
aws backup delete-backup-vault --backup-vault-name <VAULT_NAME> --region ap-northeast-1
```

---

### 13. EventBridge ルールの削除

検出された EventBridge ルール:
- `DO-NOT-DELETE-AmazonInspectorEc2ManagedRule`
- `DO-NOT-DELETE-AmazonInspectorEc2TagManagedRule`
- `DO-NOT-DELETE-AmazonInspectorEcrManagedRule`
- `DO-NOT-DELETE-AmazonInspectorLambdaManagedRule`

**注意: DO-NOT-DELETE で始まるルールは AWS Inspector 管理のため削除しないでください**

```bash
# カスタムルール一覧確認
aws events list-rules --region ap-northeast-1 --query 'Rules[*].[Name,State]' --output table

# カスタムルールのみ削除
# DO-NOT-DELETE で始まらないルールを確認して削除

# 例：カスタムルール削除
# aws events delete-rule --name <CUSTOM_RULE_NAME> --region ap-northeast-1

# ターゲット削除（必要に応じて）
# aws events remove-targets --rule <RULE_NAME> --ids "1" --region ap-northeast-1
```

---

### 14. CloudTrail の削除

```bash
# CloudTrail 一覧確認
aws cloudtrail describe-trails --region ap-northeast-1 --query 'trailList[*].[Name,S3BucketName]' --output table

# CloudTrail 削除
aws cloudtrail delete-trail --name vs-dev-ct-app --region ap-northeast-1

# 確認
aws cloudtrail describe-trails --region ap-northeast-1
```

---

### 15. IAM リソースの削除

#### IAM グループ削除

検出されたグループ:
- `dev-iam-accounting-murayama`
- `dev-iam-executive-murayama`
- `dev-iam-it-murayama`
- その他 11個

```bash
# IAM グループ一覧確認
aws iam list-groups --query 'Groups[*].GroupName' --output text

# グループからユーザー削除
aws iam get-group --group-name <GROUP_NAME> --query 'Users[*].UserName' --output text | \
  while read user; do
    aws iam remove-user-from-group --group-name <GROUP_NAME> --user-name "$user"
  done

# グループからポリシー削除
aws iam list-attached-group-policies --group-name <GROUP_NAME> --query 'AttachedPolicies[*].PolicyName' --output text | \
  while read policy; do
    aws iam detach-group-policy --group-name <GROUP_NAME> --policy-arn "arn:aws:iam::aws:policy/$policy"
  done

# グループ削除
aws iam delete-group --group-name <GROUP_NAME>

# 複数グループ削除スクリプト
for group in $(aws iam list-groups --query 'Groups[*].GroupName' --output text); do
  # グループメンバー削除
  aws iam get-group --group-name "$group" --query 'Users[*].UserName' --output text | \
    while read user; do
      echo "Removing $user from $group"
      aws iam remove-user-from-group --group-name "$group" --user-name "$user"
    done
  
  # ポリシー削除
  aws iam list-attached-group-policies --group-name "$group" --query 'AttachedPolicies[*]' --output text | \
    while read policy; do
      echo "Detaching policy from $group"
      aws iam detach-group-policy --group-name "$group" --policy-arn "$policy"
    done
  
  # グループ削除
  echo "Deleting group: $group"
  aws iam delete-group --group-name "$group"
done

# 確認
aws iam list-groups --query 'Groups[*].GroupName' --output text
```

#### IAM ロール削除（カスタムロールのみ）

```bash
# IAM ロール一覧確認
aws iam list-roles --query 'Roles[?not(RoleName | contains(@, `AWS`) and contains(@, `Service`))].RoleName' --output text

# ロールからポリシー削除
aws iam list-attached-role-policies --role-name <ROLE_NAME> --query 'AttachedPolicies[*]' --output text | \
  while read policy; do
    aws iam detach-role-policy --role-name <ROLE_NAME> --policy-arn "$policy"
  done

# インラインポリシー削除
aws iam list-role-policies --role-name <ROLE_NAME> --query 'PolicyNames' --output text | \
  while read policy; do
    aws iam delete-role-policy --role-name <ROLE_NAME> --policy-name "$policy"
  done

# ロール削除
aws iam delete-role --role-name <ROLE_NAME>
```

---

## 一括削除スクリプト（自動実行版）

リソース削除を自動化するスクリプト:

```bash
#!/bin/bash
set -e

REGION="ap-northeast-1"
DRY_RUN=true  # true で dry-run、false で実行

echo "========================================="
echo "AWS リソース削除スクリプト"
echo "========================================="
echo "Region: $REGION"
echo "Dry Run: $DRY_RUN"
echo ""

# 1. Lambda 削除
echo "【Lambda 関数削除】"
for func in $(aws lambda list-functions --region $REGION --query 'Functions[*].FunctionName' --output text); do
  echo "削除: $func"
  if [ "$DRY_RUN" = false ]; then
    aws lambda delete-function --function-name "$func" --region $REGION
  fi
done

# 2. CloudWatch Alarms 削除
echo "【CloudWatch Alarms 削除】"
for alarm in $(aws cloudwatch describe-alarms --region $REGION --query 'MetricAlarms[*].AlarmName' --output text); do
  echo "削除: $alarm"
  if [ "$DRY_RUN" = false ]; then
    aws cloudwatch delete-alarms --alarm-names "$alarm" --region $REGION
  fi
done

# 3. CloudWatch Log Groups 削除
echo "【CloudWatch Log Groups 削除】"
for log_group in $(aws logs describe-log-groups --region $REGION --query 'logGroups[*].logGroupName' --output text); do
  echo "削除: $log_group"
  if [ "$DRY_RUN" = false ]; then
    aws logs delete-log-group --log-group-name "$log_group" --region $REGION
  fi
done

# 4. S3 バケット削除
echo "【S3 バケット削除】"
for bucket in $(aws s3 ls | awk '{print $3}'); do
  echo "クリア: $bucket"
  if [ "$DRY_RUN" = false ]; then
    aws s3 rm s3://$bucket --recursive --quiet || true
    aws s3 rb s3://$bucket || true
  fi
done

echo ""
echo "========================================="
echo "削除完了（Dry Run: $DRY_RUN）"
echo "========================================="
```

---

## 削除完了確認

すべてのリソース削除後、以下で確認してください:

```bash
REGION="ap-northeast-1"

echo "EC2 インスタンス: $(aws ec2 describe-instances --region $REGION --filters "Name=instance-state-name,Values=running,stopped" --query 'Reservations | length(@)')"
echo "RDS インスタンス: $(aws rds describe-db-instances --region $REGION --query 'DBInstances | length(@)')"
echo "S3 バケット: $(aws s3 ls | wc -l)"
echo "CloudFront: $(aws cloudfront list-distributions --query 'DistributionList.Items | length(@)')"
echo "Lambda 関数: $(aws lambda list-functions --region $REGION --query 'Functions | length(@)')"
echo "CloudWatch Alarms: $(aws cloudwatch describe-alarms --region $REGION --query 'MetricAlarms | length(@)')"
echo "CloudWatch Logs: $(aws logs describe-log-groups --region $REGION --query 'logGroups | length(@)')"
```

全てが 0 または空であれば削除完了です。

---

## サポート

削除中にエラーが発生した場合:

1. **依存関係エラー**: リソースがまだ使用中の可能性があります。依存するリソースが削除されているか確認してください。

2. **アクセス拒否エラー**: IAM 権限が不足している可能性があります。管理者権限で実行してください。

3. **リソース不在エラー**: すでに削除されている可能性があります。

各コマンドに `--dry-run` フラグを追加すると、実際に削除せず実行結果をシミュレートできます。

---

**最終確認**: 削除前に必ずバックアップとスナップショットを確認し、本当に不要なリソースであることを確認してください。
