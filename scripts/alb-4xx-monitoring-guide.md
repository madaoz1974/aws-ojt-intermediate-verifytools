# ALB 4xx監視設定ガイド

**作成日**: 2025年10月31日  
**目的**: CloudWatch ログフィルターでALBログの4xxエラーを正しく検出する方法

---

## 📋 ALBログのフォーマット

ALBアクセスログの標準形式：

```
type time elb client:port target:port request_processing_time target_processing_time response_processing_time elb_status_code target_status_code received_bytes sent_bytes "request" "user_agent" ssl_cipher ssl_protocol target_group_arn trace_id domain_name chosen_cert_arn matched_rule_priority request_creation_time actions_executed redirect_url target_port protocol_version choice_reason conn_setting new_field
```

### フィールド位置（重要）

| 位置 | フィールド名 | 説明 | 例 |
|------|--------------|------|-----|
| 1 | type | ログタイプ | `http` |
| 2 | time | タイムスタンプ | `2025-10-31T08:50:07.926Z` |
| 3 | elb | ALB名 | `app/movie-dev-app-alb` |
| 4 | client | クライアント情報 | `192.0.2.1:52234` |
| 5 | target | ターゲット情報 | `10.0.1.123:8080` |
| 6 | request_processing_time | リクエスト処理時間 | `0.001` |
| 7 | target_processing_time | ターゲット処理時間 | `0.120` |
| 8 | response_processing_time | レスポンス処理時間 | `0.000` |
| **9** | **elb_status_code** | **ALBが返したステータス** | **`200`**、**`404`**、**`500`** |
| **10** | **target_status_code** | **バックエンドが返したステータス** | **`200`**、**`404`**、**`500`** |
| 11 | received_bytes | 受信バイト数 | `1000` |
| 12 | sent_bytes | 送信バイト数 | `2000` |
| 13 | request | HTTPリクエスト行 | `GET http://example.com:80/ HTTP/1.1` |
| 14 | user_agent | ユーザーエージェント | `Mozilla/5.0...` |
| ... | 以降 | その他フィールド | ... |

---

## 🔍 実際のALBログ例

### 成功レスポンス（200）

```
http 2025-10-31T08:50:07.926Z app/movie-dev-app-alb 192.0.2.1:52234 10.0.1.123:8080 0.001 0.120 0.000 200 200 1000 2000 "GET http://example.com:80/ HTTP/1.1" "Mozilla/5.0" - - arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:targetgroup/movie-dev-app-tg/73032d6629ca0073 "Root=1-6740f1fb-1234567890abcdef" "-" "-" 0 2025-10-31T08:50:07.906Z "forward" "-" "-" "10.0.1.123:8080" "HTTP/1.1" "-" "-"
```

### クライアントエラー（400番台）

```
http 2025-10-31T08:51:15.234Z app/movie-dev-app-alb 192.0.2.2:52345 10.0.1.124:8080 0.001 0.050 0.000 404 404 500 1500 "GET http://example.com:80/invalid HTTP/1.1" "Mozilla/5.0" - - arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:targetgroup/movie-dev-app-tg/73032d6629ca0073 "Root=1-6740f1fb-fedcba0987654321" "-" "-" 0 2025-10-31T08:51:15.215Z "forward" "-" "-" "10.0.1.124:8080" "HTTP/1.1" "-" "-"
```

### サーバーエラー（500番台）

```
http 2025-10-31T08:52:22.456Z app/movie-dev-app-alb 192.0.2.3:52456 10.0.1.125:8080 0.001 0.200 0.000 502 500 600 1800 "POST http://example.com:80/api HTTP/1.1" "Mozilla/5.0" - - arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:targetgroup/movie-dev-app-tg/73032d6629ca0073 "Root=1-6740f1fb-abcdef1234567890" "-" "-" 0 2025-10-31T08:52:22.432Z "forward" "-" "-" "10.0.1.125:8080" "HTTP/1.1" "-" "-"
```

---

## 📊 CloudWatch Logs メトリクスフィルター設定

### パターン仕様

CloudWatch Logs のメトリクスフィルターは、ログメッセージをスペース区切りまたはJSON形式で解析します。

ALBログはスペース区切り形式なので、以下の構文を使用します：

```
[ type, time, elb, client, target, request_time, target_time, response_time, elb_status_code, target_status_code, received_bytes, sent_bytes, request, user_agent, ssl_cipher, ssl_protocol, target_group_arn, trace_id, ...]
```

### ✅ 推奨メトリクスフィルター設定

#### **1. ALBが返した4xxエラー（404など）を検出**

**フィルターパターン：**
```
[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code="4*", ...]
```

**説明**: ALBが400番台のステータスコードを返した場合を検出

**メトリクス設定：**
- メトリクス名: `ALBClientErrors4xx`
- メトリクス値: `1`
- デフォルト値: `0`
- ユニット: `Count`

---

#### **2. バックエンドが返した4xxエラーを検出**

**フィルターパターン：**
```
[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code, target_status_code="4*", ...]
```

**説明**: バックエンドが400番台のステータスコードを返した場合を検出

**メトリクス設定：**
- メトリクス名: `TargetClientErrors4xx`
- メトリクス値: `1`
- デフォルト値: `0`
- ユニット: `Count`

---

#### **3. 5xxエラー（サーバーエラー）を検出**

**フィルターパターン：**
```
[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code="5*", ...]
```

**説明**: ALBが500番台のステータスコードを返した場合を検出

**メトリクス設定：**
- メトリクス名: `ALBServerErrors5xx`
- メトリクス値: `1`
- デフォルト値: `0`
- ユニット: `Count`

---

#### **4. 特定の4xxエラーを検出（404 Not Found）**

**フィルターパターン：**
```
[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code="404", ...]
```

**説明**: ALBが404を返した場合を検出

**メトリクス設定：**
- メトリクス名: `ALBNotFoundErrors404`
- メトリクス値: `1`
- デフォルト値: `0`
- ユニット: `Count`

---

#### **5. 特定の4xxエラーを検出（401/403 Unauthorized/Forbidden）**

**フィルターパターン：**
```
[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code="401" || elb_status_code="403", ...]
```

**説明**: ALBが認証エラーを返した場合を検出

**メトリクス設定：**
- メトリクス名: `ALBAuthErrors`
- メトリクス値: `1`
- デフォルト値: `0`
- ユニット: `Count`

---

## 📝 設定手順

### AWS CLIでの設定例

```bash
#!/bin/bash

# 変数定義
LOG_GROUP_NAME="logg-sato-alb"
METRIC_NAMESPACE="ALBMetrics"

# 1. ALBが返した4xxエラーのメトリクスフィルターを作成
aws logs put-metric-filter \
  --log-group-name "$LOG_GROUP_NAME" \
  --filter-name "ALBClientErrors4xx" \
  --filter-pattern '[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code="4*", ...]' \
  --metric-transformations \
    metricName=ALBClientErrors4xx,\
    metricNamespace="$METRIC_NAMESPACE",\
    metricValue=1,\
    defaultValue=0

# 2. バックエンドが返した4xxエラーのメトリクスフィルターを作成
aws logs put-metric-filter \
  --log-group-name "$LOG_GROUP_NAME" \
  --filter-name "TargetClientErrors4xx" \
  --filter-pattern '[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code, target_status_code="4*", ...]' \
  --metric-transformations \
    metricName=TargetClientErrors4xx,\
    metricNamespace="$METRIC_NAMESPACE",\
    metricValue=1,\
    defaultValue=0

# 3. 5xxエラーのメトリクスフィルターを作成
aws logs put-metric-filter \
  --log-group-name "$LOG_GROUP_NAME" \
  --filter-name "ALBServerErrors5xx" \
  --filter-pattern '[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code="5*", ...]' \
  --metric-transformations \
    metricName=ALBServerErrors5xx,\
    metricNamespace="$METRIC_NAMESPACE",\
    metricValue=1,\
    defaultValue=0

# 4. メトリクスフィルターの確認
aws logs describe-metric-filters \
  --log-group-name "$LOG_GROUP_NAME"
```

---

## 🔔 CloudWatch Alarmの設定例

メトリクスフィルター作成後、アラームを設定します：

```bash
#!/bin/bash

ALARM_ACTIONS="arn:aws:sns:ap-northeast-1:123456789012:sato-alb-alerts"

# 4xxエラーが1分間に5回以上発生した場合にアラート
aws cloudwatch put-metric-alarm \
  --alarm-name "ALB-4xx-Errors-High" \
  --alarm-description "ALB 4xx error rate is high" \
  --metric-name "ALBClientErrors4xx" \
  --namespace "ALBMetrics" \
  --statistic "Sum" \
  --period 60 \
  --threshold 5 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --evaluation-periods 1 \
  --alarm-actions "$ALARM_ACTIONS"

# 5xxエラーが1分間に1回以上発生した場合にアラート（より厳しい条件）
aws cloudwatch put-metric-alarm \
  --alarm-name "ALB-5xx-Errors-Critical" \
  --alarm-description "ALB 5xx error detected" \
  --metric-name "ALBServerErrors5xx" \
  --namespace "ALBMetrics" \
  --statistic "Sum" \
  --period 60 \
  --threshold 1 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --evaluation-periods 1 \
  --alarm-actions "$ALARM_ACTIONS"
```

---

## 🧪 テスト方法

### 1. メトリクスフィルターのテスト

CloudWatch Logs コンソールで：

1. ロググループ「logg-sato-alb」を開く
2. 「メトリクスフィルターの作成」または「編集」を選択
3. 「テストパターン」セクションで、実際のALBログをサンプルとしてペーストして動作確認

**テスト用サンプルログ：**

```
http 2025-10-31T08:51:15.234Z app/movie-dev-app-alb 192.0.2.2:52345 10.0.1.124:8080 0.001 0.050 0.000 404 404 500 1500 "GET http://example.com:80/invalid HTTP/1.1" "Mozilla/5.0" - - arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:targetgroup/movie-dev-app-tg/73032d6629ca0073 "Root=1-6740f1fb-fedcba0987654321" "-" "-" 0 2025-10-31T08:51:15.215Z "forward" "-" "-" "10.0.1.124:8080" "HTTP/1.1" "-" "-"
```

### 2. メトリクスの確認

```bash
# メトリクス情報を確認
aws cloudwatch list-metrics \
  --namespace "ALBMetrics" \
  --metric-name "ALBClientErrors4xx"

# メトリクスデータを取得
aws cloudwatch get-metric-statistics \
  --namespace "ALBMetrics" \
  --metric-name "ALBClientErrors4xx" \
  --start-time 2025-10-31T00:00:00Z \
  --end-time 2025-10-31T23:59:59Z \
  --period 300 \
  --statistics Sum
```

### 3. アラームの確認

```bash
# アラーム一覧を確認
aws cloudwatch describe-alarms \
  --alarm-names "ALB-4xx-Errors-High"

# アラームの履歴を確認
aws cloudwatch describe-alarm-history \
  --alarm-name "ALB-4xx-Errors-High"
```

---

## 🔧 トラブルシューティング

### 問題1: メトリクスフィルターがログにマッチしない

**原因**: フィルターパターンが正確でない、またはログ形式が異なる

**対処**:
1. CloudWatch Logs コンソールでログを確認して実際の形式を確認
2. パターンの括弧とフィールド数を確認
3. テストパターン機能で動作確認

### 問題2: メトリクスが表示されない

**原因**: ログフィルターは動作しているがメトリクスが作成されていない

**対処**:
```bash
# メトリクスフィルターを確認
aws logs describe-metric-filters \
  --log-group-name "logg-sato-alb"

# ロググループに新しいログが到着するのを待つ
# CloudWatch Logs は新しいログに対してのみメトリクスを計算します
```

### 問題3: アラームが発火しない

**原因**: メトリクスは作成されているがしきい値に達していない

**対処**:
1. 実際のメトリクス値を確認
2. しきい値を調整
3. 統計期間を確認（Sum/Average/Max等）

```bash
# メトリクスの統計情報を確認
aws cloudwatch get-metric-statistics \
  --namespace "ALBMetrics" \
  --metric-name "ALBClientErrors4xx" \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Sum,Average,Maximum
```

---

## 📚 参考情報

### AWS ドキュメント
- [CloudWatch Logs メトリクスフィルター構文](https://docs.aws.amazon.com/ja_jp/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html)
- [ALB アクセスログ](https://docs.aws.amazon.com/ja_jp/elasticloadbalancing/latest/application/load-balancer-access-logs.html)
- [CloudWatch Alarms](https://docs.aws.amazon.com/ja_jp/AmazonCloudWatch/latest/events/WhatIsCloudWatch.html)

### 関連する設定例
- [ALB ログを S3 に保存](https://docs.aws.amazon.com/ja_jp/elasticloadbalancing/latest/application/load-balancer-access-logs.html)
- [S3 から Lambda で処理](https://docs.aws.amazon.com/ja_jp/lambda/latest/dg/with-s3.html)

---

## 📋 チェックリスト

実装時の確認項目：

- [ ] ロググループ名を確認（`logg-sato-alb`）
- [ ] Lambda 関数がログをコンテナ 可能に送信していることを確認
- [ ] メトリクスフィルターの構文が正確であることを確認
- [ ] テストパターンで実際のログでマッチすることを確認
- [ ] メトリクスが CloudWatch コンソールで表示されることを確認
- [ ] アラームが作成されていることを確認
- [ ] SNS トピックがアラームアクションに設定されていることを確認
- [ ] SNS サブスクリプションがメールアドレスで設定されていることを確認
- [ ] メール確認がされていることを確認

---

**作成者**: AWS OJT 中級コース サポート  
**最終更新**: 2025年10月31日

