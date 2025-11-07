#!/bin/bash

# ALB 4xx エラー監視設定スクリプト
# CloudWatch Logs メトリクスフィルターとアラームを自動作成

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

# ロググループ名
LOG_GROUP_NAME="${1:-logg-sato-alb}"

# メトリクスネームスペース
METRIC_NAMESPACE="ALBMetrics"

# SNS トピック ARN（メール通知用）
SNS_TOPIC_ARN="${2:-}"

# ===========================
# 前提確認
# ===========================

log "前提条件の確認..."

# AWS CLI の確認
if ! command -v aws &> /dev/null; then
    error "AWS CLI がインストールされていません"
    exit 1
fi

success "AWS CLI が見つかりました"

# ロググループの確認
if ! aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" --query "logGroups[?logGroupName=='$LOG_GROUP_NAME']" | grep -q "$LOG_GROUP_NAME"; then
    error "ロググループ '$LOG_GROUP_NAME' が見つかりません"
    exit 1
fi

success "ロググループ '$LOG_GROUP_NAME' を確認しました"

# ===========================
# メトリクスフィルター作成
# ===========================

log ""
log "メトリクスフィルターを作成します..."
log ""

# 1. ALBが返した4xxエラーのメトリクスフィルター
log "1. ALBClientErrors4xx メトリクスフィルターを作成中..."
aws logs put-metric-filter \
    --log-group-name "$LOG_GROUP_NAME" \
    --filter-name "ALBClientErrors4xx" \
    --filter-pattern '[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code="4*", ...]' \
    --metric-transformations \
        metricName=ALBClientErrors4xx,\
        metricNamespace="$METRIC_NAMESPACE",\
        metricValue=1,\
        defaultValue=0 2>/dev/null

success "ALBClientErrors4xx メトリクスフィルターを作成しました"

# 2. バックエンドが返した4xxエラーのメトリクスフィルター
log "2. TargetClientErrors4xx メトリクスフィルターを作成中..."
aws logs put-metric-filter \
    --log-group-name "$LOG_GROUP_NAME" \
    --filter-name "TargetClientErrors4xx" \
    --filter-pattern '[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code, target_status_code="4*", ...]' \
    --metric-transformations \
        metricName=TargetClientErrors4xx,\
        metricNamespace="$METRIC_NAMESPACE",\
        metricValue=1,\
        defaultValue=0 2>/dev/null

success "TargetClientErrors4xx メトリクスフィルターを作成しました"

# 3. 5xxエラーのメトリクスフィルター
log "3. ALBServerErrors5xx メトリクスフィルターを作成中..."
aws logs put-metric-filter \
    --log-group-name "$LOG_GROUP_NAME" \
    --filter-name "ALBServerErrors5xx" \
    --filter-pattern '[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code="5*", ...]' \
    --metric-transformations \
        metricName=ALBServerErrors5xx,\
        metricNamespace="$METRIC_NAMESPACE",\
        metricValue=1,\
        defaultValue=0 2>/dev/null

success "ALBServerErrors5xx メトリクスフィルターを作成しました"

# 4. 404エラーのメトリクスフィルター
log "4. ALBNotFoundErrors404 メトリクスフィルターを作成中..."
aws logs put-metric-filter \
    --log-group-name "$LOG_GROUP_NAME" \
    --filter-name "ALBNotFoundErrors404" \
    --filter-pattern '[type, time, elb, client, target, request_time, target_time, response_time, elb_status_code="404", ...]' \
    --metric-transformations \
        metricName=ALBNotFoundErrors404,\
        metricNamespace="$METRIC_NAMESPACE",\
        metricValue=1,\
        defaultValue=0 2>/dev/null

success "ALBNotFoundErrors404 メトリクスフィルターを作成しました"

# ===========================
# メトリクスフィルターの確認
# ===========================

log ""
log "メトリクスフィルターの確認..."

aws logs describe-metric-filters \
    --log-group-name "$LOG_GROUP_NAME" \
    --query 'metricFilters[*].[filterName, filterPattern]' \
    --output table

# ===========================
# アラーム作成（SNS設定がある場合）
# ===========================

if [ -n "$SNS_TOPIC_ARN" ]; then
    log ""
    log "CloudWatch Alarms を作成します..."
    log ""
    
    # 1. 4xxエラーアラーム
    log "1. ALB-4xx-Errors-High アラームを作成中..."
    aws cloudwatch put-metric-alarm \
        --alarm-name "ALB-4xx-Errors-High" \
        --alarm-description "ALB 4xx error rate is high" \
        --metric-name "ALBClientErrors4xx" \
        --namespace "$METRIC_NAMESPACE" \
        --statistic "Sum" \
        --period 60 \
        --threshold 5 \
        --comparison-operator "GreaterThanOrEqualToThreshold" \
        --evaluation-periods 1 \
        --alarm-actions "$SNS_TOPIC_ARN" 2>/dev/null
    
    success "ALB-4xx-Errors-High アラームを作成しました"
    
    # 2. 5xxエラーアラーム（より厳しい条件）
    log "2. ALB-5xx-Errors-Critical アラームを作成中..."
    aws cloudwatch put-metric-alarm \
        --alarm-name "ALB-5xx-Errors-Critical" \
        --alarm-description "ALB 5xx error detected - immediate attention required" \
        --metric-name "ALBServerErrors5xx" \
        --namespace "$METRIC_NAMESPACE" \
        --statistic "Sum" \
        --period 60 \
        --threshold 1 \
        --comparison-operator "GreaterThanOrEqualToThreshold" \
        --evaluation-periods 1 \
        --alarm-actions "$SNS_TOPIC_ARN" 2>/dev/null
    
    success "ALB-5xx-Errors-Critical アラームを作成しました"
    
    # 3. 404エラーアラーム
    log "3. ALB-404-Errors-Warning アラームを作成中..."
    aws cloudwatch put-metric-alarm \
        --alarm-name "ALB-404-Errors-Warning" \
        --alarm-description "ALB 404 Not Found errors detected" \
        --metric-name "ALBNotFoundErrors404" \
        --namespace "$METRIC_NAMESPACE" \
        --statistic "Sum" \
        --period 300 \
        --threshold 20 \
        --comparison-operator "GreaterThanOrEqualToThreshold" \
        --evaluation-periods 1 \
        --alarm-actions "$SNS_TOPIC_ARN" 2>/dev/null
    
    success "ALB-404-Errors-Warning アラームを作成しました"
    
    # ===========================
    # アラーム確認
    # ===========================
    
    log ""
    log "作成されたアラームの確認..."
    
    aws cloudwatch describe-alarms \
        --alarm-names "ALB-4xx-Errors-High" "ALB-5xx-Errors-Critical" "ALB-404-Errors-Warning" \
        --query 'MetricAlarms[*].[AlarmName, StateValue, MetricName]' \
        --output table 2>/dev/null || warning "アラーム情報を取得できません"
    
else
    warning "SNS トピック ARN が設定されていないため、アラームは作成されません"
    warning "アラームを作成するには以下のコマンドを実行してください："
    echo ""
    echo "  $0 \"$LOG_GROUP_NAME\" \"arn:aws:sns:ap-northeast-1:123456789012:your-topic-name\""
    echo ""
fi

# ===========================
# 確認方法の表示
# ===========================

log ""
log "============================="
log "メトリクスフィルター設定完了"
log "============================="
log ""

success "以下のメトリクスフィルターが作成されました："
echo "  • ALBClientErrors4xx     - ALBが返した4xxエラー"
echo "  • TargetClientErrors4xx  - バックエンドが返した4xxエラー"
echo "  • ALBServerErrors5xx     - ALBが返した5xxエラー"
echo "  • ALBNotFoundErrors404   - 404エラー"
echo ""

log "メトリクスの確認方法："
echo "  # メトリクス一覧"
echo "  aws cloudwatch list-metrics --namespace \"$METRIC_NAMESPACE\""
echo ""
echo "  # メトリクスデータ取得"
echo "  aws cloudwatch get-metric-statistics \\"
echo "    --namespace \"$METRIC_NAMESPACE\" \\"
echo "    --metric-name \"ALBClientErrors4xx\" \\"
echo "    --start-time \$(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \\"
echo "    --end-time \$(date -u +%Y-%m-%dT%H:%M:%SZ) \\"
echo "    --period 60 \\"
echo "    --statistics Sum"
echo ""

log "アラーム確認方法："
echo "  # アラーム一覧"
echo "  aws cloudwatch describe-alarms --alarm-name-prefix \"ALB-\""
echo ""
echo "  # アラーム詳細"
echo "  aws cloudwatch describe-alarms --alarm-names \"ALB-4xx-Errors-High\""
echo ""

log "CloudWatch Logs の確認："
echo "  # ロググループ内のログ確認"
echo "  aws logs tail \"$LOG_GROUP_NAME\" --follow"
echo ""

log "次のステップ："
echo "  1. ALB からのアクセスログがロググループに送信されていることを確認"
echo "  2. 実際の 4xx エラーが発生してメトリクスが記録されるのを待つ"
echo "  3. CloudWatch コンソールでメトリクスが表示されることを確認"
echo "  4. アラームが発火してメール通知が届くことを確認"
echo ""

success "設定スクリプトが完了しました"

