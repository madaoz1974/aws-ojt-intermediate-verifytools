#!/bin/bash

# ALB 4xx 監視トラブルシューティングスクリプト
# メトリクスフィルター、メトリクス、アラームの診断を実施

set -e

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ロギング関数
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# ===========================
# 設定セクション
# ===========================

LOG_GROUP_NAME="${1:-logg-sato-alb}"
METRIC_NAMESPACE="ALBMetrics"

# ===========================
# 診断開始
# ===========================

log "============================="
log "ALB 4xx 監視設定の診断を開始します"
log "============================="
log ""

# ===========================
# 1. ロググループの確認
# ===========================

log "【診断1】ロググループの確認..."

if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" --query "logGroups[?logGroupName=='$LOG_GROUP_NAME']" | grep -q "$LOG_GROUP_NAME"; then
    success "ロググループ '$LOG_GROUP_NAME' が存在します"
    
    # ロググループの詳細情報
    log "ロググループの詳細情報："
    aws logs describe-log-groups \
        --log-group-name-prefix "$LOG_GROUP_NAME" \
        --query "logGroups[?logGroupName=='$LOG_GROUP_NAME'].[logGroupName, creationTime, retentionInDays, storedBytes]" \
        --output table
    
    log ""
    
else
    error "ロググループ '$LOG_GROUP_NAME' が見つかりません"
    exit 1
fi

# ===========================
# 2. ロググループのログストリーム確認
# ===========================

log "【診断2】ロググループのログストリーム確認..."

STREAM_COUNT=$(aws logs describe-log-streams \
    --log-group-name "$LOG_GROUP_NAME" \
    --query 'logStreams | length(@)' \
    --output text)

if [ "$STREAM_COUNT" -gt 0 ]; then
    success "ログストリームが $STREAM_COUNT 個見つかりました"
    
    log "最新のログストリーム（最大10個）："
    aws logs describe-log-streams \
        --log-group-name "$LOG_GROUP_NAME" \
        --order-by "LastEventTime" \
        --descending \
        --max-items 10 \
        --query 'logStreams[*].[logStreamName, creationTime, lastEventTimestamp, storedBytes]' \
        --output table
    
    log ""
    
else
    warning "ログストリームが見つかりません"
    warning "Lambda 関数がログを送信していない可能性があります"
    log ""
fi

# ===========================
# 3. メトリクスフィルターの確認
# ===========================

log "【診断3】メトリクスフィルターの確認..."

FILTER_COUNT=$(aws logs describe-metric-filters \
    --log-group-name "$LOG_GROUP_NAME" \
    --query 'metricFilters | length(@)' \
    --output text)

if [ "$FILTER_COUNT" -gt 0 ]; then
    success "メトリクスフィルターが $FILTER_COUNT 個見つかりました"
    
    log "メトリクスフィルターの詳細："
    aws logs describe-metric-filters \
        --log-group-name "$LOG_GROUP_NAME" \
        --query 'metricFilters[*].[filterName, filterPattern, metricTransformations[0].metricName]' \
        --output table
    
    log ""
    
else
    error "メトリクスフィルターが見つかりません"
    error "→ メトリクスフィルターを作成する必要があります"
    log "   setup-alb-4xx-monitoring.sh スクリプトを実行してください"
    log ""
fi

# ===========================
# 4. 最新のログを確認
# ===========================

log "【診断4】最新のログメッセージ確認..."

if [ "$STREAM_COUNT" -gt 0 ]; then
    
    # 最新のログストリームを取得
    LATEST_STREAM=$(aws logs describe-log-streams \
        --log-group-name "$LOG_GROUP_NAME" \
        --order-by "LastEventTime" \
        --descending \
        --max-items 1 \
        --query 'logStreams[0].logStreamName' \
        --output text)
    
    log "最新のログストリーム: $LATEST_STREAM"
    
    # 最新のログイベントを取得
    LOG_EVENTS=$(aws logs get-log-events \
        --log-group-name "$LOG_GROUP_NAME" \
        --log-stream-name "$LATEST_STREAM" \
        --limit 5 \
        --query 'events[-1]' \
        --output json)
    
    MESSAGE=$(echo "$LOG_EVENTS" | jq -r '.message // empty')
    
    if [ -n "$MESSAGE" ]; then
        success "最新のログメッセージを取得しました"
        log "メッセージ内容："
        echo "  $MESSAGE" | head -c 200
        echo "..."
        log ""
        
        # ログフォーマットの検証
        log "ログフォーマット検証:"
        if echo "$MESSAGE" | grep -q "^http "; then
            success "ALBログフォーマットが正確です（'http' で開始）"
        else
            warning "ALBログフォーマットが異なる可能性があります"
        fi
        
        # ステータスコードフィールドの確認
        STATUS_FIELD=$(echo "$MESSAGE" | awk '{print $9}')
        if [ -n "$STATUS_FIELD" ]; then
            log "ALBのステータスコード位置（フィールド9）: $STATUS_FIELD"
            if [[ "$STATUS_FIELD" =~ ^[0-9]+$ ]]; then
                success "ステータスコードが正しい形式です"
            fi
        fi
        
        log ""
    else
        error "ログメッセージが見つかりません"
        error "→ ログが正しく送信されていない可能性があります"
        log ""
    fi
else
    error "ログストリームがないため、ログメッセージを確認できません"
    log ""
fi

# ===========================
# 5. メトリクスデータの確認
# ===========================

log "【診断5】メトリクスデータの確認..."

METRICS=$(aws cloudwatch list-metrics \
    --namespace "$METRIC_NAMESPACE" \
    --query 'Metrics[*].MetricName' \
    --output text)

if [ -n "$METRICS" ]; then
    success "メトリクスが見つかりました："
    echo "  $METRICS"
    log ""
    
    # 各メトリクスのデータ確認
    for METRIC in $METRICS; do
        log "メトリクス '$METRIC' のデータを確認中..."
        
        STATS=$(aws cloudwatch get-metric-statistics \
            --namespace "$METRIC_NAMESPACE" \
            --metric-name "$METRIC" \
            --start-time "$(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ)" \
            --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --period 300 \
            --statistics Sum \
            --query 'Datapoints | length(@)' \
            --output text)
        
        if [ "$STATS" -gt 0 ]; then
            success "  → $METRIC のデータが $STATS 個見つかりました"
        else
            warning "  → $METRIC のデータが見つかりません（ログの4xxエラーが発生していない可能性）"
        fi
    done
    
    log ""
    
else
    error "メトリクスが見つかりません"
    error "→ メトリクスフィルターが正しく作成されていない、またはまだ 4xx エラーが発生していない可能性があります"
    log ""
fi

# ===========================
# 6. CloudWatch Alarms の確認
# ===========================

log "【診断6】CloudWatch Alarms の確認..."

ALARM_COUNT=$(aws cloudwatch describe-alarms \
    --query 'MetricAlarms | length(@)' \
    --output text)

ALB_ALARMS=$(aws cloudwatch describe-alarms \
    --alarm-name-prefix "ALB-" \
    --query 'MetricAlarms | length(@)' \
    --output text)

if [ "$ALB_ALARMS" -gt 0 ]; then
    success "ALB関連のアラームが $ALB_ALARMS 個見つかりました"
    
    log "ALB関連のアラーム一覧："
    aws cloudwatch describe-alarms \
        --alarm-name-prefix "ALB-" \
        --query 'MetricAlarms[*].[AlarmName, StateValue, MetricName, Threshold]' \
        --output table
    
    log ""
    
else
    warning "ALB関連のアラームが見つかりません"
    warning "→ アラームが作成されていない、または SNS トピックの設定が不完全な可能性があります"
    log ""
fi

# ===========================
# 7. SNS トピックの確認
# ===========================

log "【診断7】SNS トピックの確認..."

SNS_TOPICS=$(aws sns list-topics \
    --query 'Topics[*].TopicArn' \
    --output text)

if [ -n "$SNS_TOPICS" ]; then
    success "SNS トピックが見つかりました："
    
    for TOPIC_ARN in $SNS_TOPICS; do
        TOPIC_NAME=$(echo "$TOPIC_ARN" | awk -F':' '{print $NF}')
        
        # サブスクリプション確認
        SUBSCRIPTIONS=$(aws sns list-subscriptions-by-topic \
            --topic-arn "$TOPIC_ARN" \
            --query 'Subscriptions' \
            --output json)
        
        SUB_COUNT=$(echo "$SUBSCRIPTIONS" | jq 'length')
        
        log "  Topic: $TOPIC_NAME"
        log "    ARN: $TOPIC_ARN"
        log "    サブスクリプション数: $SUB_COUNT"
        
        # メールサブスクリプションの確認
        EMAIL_SUBS=$(echo "$SUBSCRIPTIONS" | jq -r '.[] | select(.Protocol=="email") | .Endpoint')
        if [ -n "$EMAIL_SUBS" ]; then
            log "    メール登録:"
            echo "$EMAIL_SUBS" | while read -r EMAIL; do
                STATUS=$(aws sns list-subscriptions-by-topic \
                    --topic-arn "$TOPIC_ARN" \
                    --query "Subscriptions[?Endpoint=='$EMAIL'].SubscriptionArn" \
                    --output text)
                
                if [[ "$STATUS" == *"PendingConfirmation"* ]]; then
                    warning "      - $EMAIL (確認待ち)"
                else
                    success "      - $EMAIL (確認済み)"
                fi
            done
        fi
    done
    
    log ""
    
else
    warning "SNS トピックが見つかりません"
    warning "→ メール通知を設定する必要があります"
    log ""
fi

# ===========================
# 8. Lambda 関数の確認
# ===========================

log "【診断8】Lambda 関数の確認..."

LAMBDA_FUNCTIONS=$(aws lambda list-functions \
    --query 'Functions[?Description contains `ALB`].FunctionName' \
    --output text)

if [ -z "$LAMBDA_FUNCTIONS" ]; then
    log "Lambda 関数の確認:"
    
    # ALB ログ送信用の Lambda 関数を探す
    LAMBDA_FUNCTIONS=$(aws lambda list-functions \
        --query 'Functions[*].FunctionName' \
        --output text | head -5)
fi

if [ -n "$LAMBDA_FUNCTIONS" ]; then
    success "Lambda 関数が見つかりました"
    
    for FUNC in $LAMBDA_FUNCTIONS; do
        log "  関数: $FUNC"
        
        # 最新の実行を確認
        RECENT_INVOCATION=$(aws lambda get-function \
            --function-name "$FUNC" \
            --query 'Configuration.[LastModified, Runtime]' \
            --output json)
        
        echo "$RECENT_INVOCATION" | jq '.'
    done
    
    log ""
else
    warning "Lambda 関数が見つかりません"
    warning "→ ALB ログを CloudWatch Logs に送信する Lambda 関数が設定されていない可能性があります"
    log ""
fi

# ===========================
# 9. 推奨される次のステップ
# ===========================

log "============================="
log "診断レポート"
log "============================="
log ""

# 総合診断
HAS_LOG_STREAM=false
HAS_METRIC_FILTER=false
HAS_METRICS=false
HAS_ALARMS=false

if [ "$STREAM_COUNT" -gt 0 ]; then HAS_LOG_STREAM=true; fi
if [ "$FILTER_COUNT" -gt 0 ]; then HAS_METRIC_FILTER=true; fi
if [ -n "$METRICS" ]; then HAS_METRICS=true; fi
if [ "$ALB_ALARMS" -gt 0 ]; then HAS_ALARMS=true; fi

log "確認された状態："
[ "$HAS_LOG_STREAM" = true ] && success "✓ ロググループにログストリームがある" || error "✗ ロググループにログが送信されていない"
[ "$HAS_METRIC_FILTER" = true ] && success "✓ メトリクスフィルターが設定されている" || error "✗ メトリクスフィルターが設定されていない"
[ "$HAS_METRICS" = true ] && success "✓ メトリクスが生成されている" || warning "⚠ メトリクスが生成されていない（4xxエラーが発生していない可能性）"
[ "$HAS_ALARMS" = true ] && success "✓ アラームが設定されている" || warning "⚠ アラームが設定されていない"

log ""
log "推奨される対応："
log ""

if [ "$HAS_LOG_STREAM" = false ]; then
    error "【優先度: 高】ログが送信されていません"
    log "  対応:"
    log "  1. Lambda 関数の S3 イベント トリガーが正しく設定されているか確認"
    log "  2. Lambda 関数のログを確認"
    log "     aws logs tail /aws/lambda/<function-name> --follow"
    log "  3. ALB のアクセスログが S3 に保存されているか確認"
    log ""
fi

if [ "$HAS_METRIC_FILTER" = false ]; then
    error "【優先度: 高】メトリクスフィルターが設定されていません"
    log "  対応:"
    log "  1. setup-alb-4xx-monitoring.sh スクリプトを実行"
    log "     bash scripts/setup-alb-4xx-monitoring.sh \"$LOG_GROUP_NAME\" \"<SNS_TOPIC_ARN>\""
    log ""
fi

if [ "$HAS_LOG_STREAM" = true ] && [ "$HAS_METRIC_FILTER" = true ] && [ "$HAS_METRICS" = false ]; then
    warning "【優先度: 中】メトリクスが生成されていません"
    log "  対応:"
    log "  1. CloudWatch Logs のテストパターン機能でログがフィルターにマッチするか確認"
    log "  2. ログの形式が ALB 標準形式か確認"
    log "  3. 実際に 4xx エラーが発生するようにアプリケーションをテスト"
    log ""
fi

if [ "$HAS_ALARMS" = false ]; then
    warning "【優先度: 中】アラームが設定されていません"
    log "  対応:"
    log "  1. SNS トピックの ARN を確認"
    log "  2. setup-alb-4xx-monitoring.sh スクリプトに SNS トピック ARN を指定して実行"
    log "     bash scripts/setup-alb-4xx-monitoring.sh \"$LOG_GROUP_NAME\" \"<SNS_TOPIC_ARN>\""
    log ""
fi

# ===========================
# テスト用コマンド
# ===========================

log "============================="
log "テスト・確認用コマンド"
log "============================="
log ""

log "1. ロググループのログを確認:"
echo "  aws logs tail \"$LOG_GROUP_NAME\" --follow"
log ""

log "2. メトリクス値を確認:"
echo "  aws cloudwatch get-metric-statistics \\"
echo "    --namespace \"$METRIC_NAMESPACE\" \\"
echo "    --metric-name \"ALBClientErrors4xx\" \\"
echo "    --start-time \$(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \\"
echo "    --end-time \$(date -u +%Y-%m-%dT%H:%M:%SZ) \\"
echo "    --period 60 \\"
echo "    --statistics Sum"
log ""

log "3. アラーム状態を確認:"
echo "  aws cloudwatch describe-alarms --alarm-name-prefix \"ALB-\""
log ""

log "4. Lambda 関数のログを確認:"
echo "  aws logs tail /aws/lambda/ --follow"
log ""

success "診断が完了しました"

