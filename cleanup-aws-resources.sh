#!/bin/bash

# AWS リソース削除スクリプト
# 使用方法: bash cleanup-aws-resources.sh [--dry-run|--execute]

set -e

REGION="ap-northeast-1"
MODE="${1:---dry-run}"  # デフォルトは dry-run

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ログ関数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_action() {
    if [ "$MODE" = "--dry-run" ]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $1"
    else
        echo -e "${RED}[実行]${NC} $1"
    fi
}

# ヘッダー表示
print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

# 実行確認
confirm_execution() {
    if [ "$MODE" = "--execute" ]; then
        log_warning "リソース削除を開始します。この操作は元に戻せません。"
        read -p "本当に実行しますか？ (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            echo "キャンセルしました。"
            exit 1
        fi
    fi
}

# コマンド実行ヘルパー
execute_cmd() {
    local cmd=$1
    local description=$2
    
    if [ "$MODE" = "--dry-run" ]; then
        log_action "$description"
        echo "  実行コマンド: $cmd"
    else
        log_action "$description"
        eval "$cmd" || log_error "実行失敗: $description"
    fi
}

print_header "AWS リソース削除スクリプト"

echo "Mode: $MODE"
echo "Region: $REGION"
echo ""

if [ "$MODE" = "--dry-run" ]; then
    log_info "ドライランモードです。削除は実行されません。"
    log_info "実際に削除するには --execute オプションを指定してください。"
elif [ "$MODE" = "--execute" ]; then
    confirm_execution
    log_warning "リソース削除を開始します..."
else
    log_error "無効なオプションです。--dry-run または --execute を指定してください。"
    exit 1
fi

echo ""

# ===== 削除処理開始 =====

# 1. CodePipeline の削除
print_header "1. CodePipeline 削除"

pipelines=$(aws codepipeline list-pipelines --region $REGION --query 'pipelines[*].name' --output text 2>/dev/null || echo "")
if [ -n "$pipelines" ]; then
    for pipeline in $pipelines; do
        execute_cmd "aws codepipeline delete-pipeline --name \"$pipeline\" --region $REGION" \
            "CodePipeline 削除: $pipeline"
    done
else
    log_info "CodePipeline はありません。"
fi

# 2. Lambda 関数の削除
print_header "2. Lambda 関数 削除"

lambda_funcs=$(aws lambda list-functions --region $REGION --query 'Functions[*].FunctionName' --output text 2>/dev/null || echo "")
if [ -n "$lambda_funcs" ]; then
    for func in $lambda_funcs; do
        execute_cmd "aws lambda delete-function --function-name \"$func\" --region $REGION" \
            "Lambda 削除: $func"
    done
else
    log_info "Lambda 関数はありません。"
fi

# 3. CloudFront Distribution の削除
print_header "3. CloudFront Distribution 削除"

cf_distributions=$(aws cloudfront list-distributions --query 'DistributionList.Items[*].Id' --output text 2>/dev/null || echo "")
if [ -n "$cf_distributions" ]; then
    for dist_id in $cf_distributions; do
        log_action "CloudFront Distribution 無効化・削除: $dist_id"
        
        if [ "$MODE" = "--execute" ]; then
            # Distribution 情報取得
            dist_config=$(aws cloudfront get-distribution --id "$dist_id" 2>/dev/null || echo "")
            
            if [ -n "$dist_config" ]; then
                etag=$(echo "$dist_config" | jq -r '.ETag')
                dist_config_body=$(echo "$dist_config" | jq '.Distribution.DistributionConfig | .Enabled = false')
                
                # 無効化
                aws cloudfront update-distribution --id "$dist_id" \
                    --distribution-config "$(echo "$dist_config_body" | jq -c '.')" \
                    --if-match "$etag" 2>/dev/null || true
                
                # 削除待機
                log_info "Distribution 削除待機中（最大3分）..."
                for i in {1..30}; do
                    status=$(aws cloudfront get-distribution --id "$dist_id" --query 'Distribution.Status' --output text 2>/dev/null || echo "DELETED")
                    
                    if [ "$status" = "Deployed" ]; then
                        # 削除
                        etag=$(aws cloudfront get-distribution --id "$dist_id" --query 'ETag' --output text 2>/dev/null || echo "")
                        if [ -n "$etag" ]; then
                            aws cloudfront delete-distribution --id "$dist_id" --if-match "$etag" 2>/dev/null || true
                            log_success "CloudFront 削除完了: $dist_id"
                        fi
                        break
                    fi
                    
                    sleep 6
                done
            fi
        else
            echo "  実行コマンド: aws cloudfront update-distribution (無効化後に削除)"
        fi
    done
else
    log_info "CloudFront Distribution はありません。"
fi

# 4. Application Load Balancer の削除
print_header "4. ロードバランサー (ALB) 削除"

albs=$(aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers[*].LoadBalancerArn' --output text 2>/dev/null || echo "")
if [ -n "$albs" ]; then
    for alb_arn in $albs; do
        alb_name=$(echo "$alb_arn" | awk -F: '{print $NF}' | awk -F/ '{print $(NF-1)"/"$NF}')
        execute_cmd "aws elbv2 delete-load-balancer --load-balancer-arn \"$alb_arn\" --region $REGION" \
            "ALB 削除: $alb_name"
    done
else
    log_info "ロードバランサーはありません。"
fi

# 5. EC2 インスタンスの削除
print_header "5. EC2 インスタンス 削除"

instances=$(aws ec2 describe-instances --region $REGION --filters "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null || echo "")

if [ -n "$instances" ]; then
    for instance_id in $instances; do
        execute_cmd "aws ec2 terminate-instances --instance-ids \"$instance_id\" --region $REGION" \
            "EC2 インスタンス 削除: $instance_id"
    done
else
    log_info "EC2 インスタンスはありません。"
fi

# 6. Elastic IP の削除
print_header "6. Elastic IP 削除"

eips=$(aws ec2 describe-addresses --region $REGION --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null || echo "")
if [ -n "$eips" ]; then
    for alloc_id in $eips; do
        execute_cmd "aws ec2 release-address --allocation-id \"$alloc_id\" --region $REGION" \
            "Elastic IP 削除: $alloc_id"
    done
else
    log_info "未割り当ての Elastic IP はありません。"
fi

# 7. EBS スナップショットの削除
print_header "7. EBS スナップショット 削除"

snapshots=$(aws ec2 describe-snapshots --region $REGION --owner-ids self \
  --query 'Snapshots[*].SnapshotId' --output text 2>/dev/null || echo "")

if [ -n "$snapshots" ]; then
    for snapshot_id in $snapshots; do
        execute_cmd "aws ec2 delete-snapshot --snapshot-id \"$snapshot_id\" --region $REGION" \
            "EBS スナップショット 削除: $snapshot_id"
    done
else
    log_info "EBS スナップショットはありません。"
fi

# 8. RDS インスタンスの削除
print_header "8. RDS インスタンス 削除"

rds_instances=$(aws rds describe-db-instances --region $REGION \
  --query 'DBInstances[*].DBInstanceIdentifier' --output text 2>/dev/null || echo "")

if [ -n "$rds_instances" ]; then
    for db_id in $rds_instances; do
        execute_cmd "aws rds delete-db-instance --db-instance-identifier \"$db_id\" --skip-final-snapshot --region $REGION" \
            "RDS インスタンス 削除: $db_id"
    done
else
    log_info "RDS インスタンスはありません。"
fi

# 9. RDS スナップショットの削除
print_header "9. RDS スナップショット 削除"

rds_snapshots=$(aws rds describe-db-snapshots --region $REGION \
  --query 'DBSnapshots[*].DBSnapshotIdentifier' --output text 2>/dev/null || echo "")

if [ -n "$rds_snapshots" ]; then
    for snapshot_id in $rds_snapshots; do
        execute_cmd "aws rds delete-db-snapshot --db-snapshot-identifier \"$snapshot_id\" --region $REGION" \
            "RDS スナップショット 削除: $snapshot_id"
    done
else
    log_info "RDS スナップショットはありません。"
fi

# 10. S3 バケットの削除
print_header "10. S3 バケット 削除"

s3_buckets=$(aws s3 ls | awk '{print $3}' | grep -v "^$" || echo "")
if [ -n "$s3_buckets" ]; then
    for bucket in $s3_buckets; do
        log_action "S3 バケット クリア・削除: $bucket"
        
        if [ "$MODE" = "--execute" ]; then
            # バケット内のオブジェクト削除
            aws s3 rm s3://$bucket --recursive --quiet 2>/dev/null || true
            
            # バージョニング有効時のバージョン削除
            aws s3api list-object-versions --bucket "$bucket" \
              --query 'Versions[*].[Key,VersionId]' --output text 2>/dev/null | \
              while read key version; do
                aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version" 2>/dev/null || true
              done
            
            # 削除マーカー削除
            aws s3api list-object-versions --bucket "$bucket" \
              --query 'DeleteMarkers[*].[Key,VersionId]' --output text 2>/dev/null | \
              while read key version; do
                aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version" 2>/dev/null || true
              done
            
            # バケット削除
            aws s3 rb s3://$bucket --force 2>/dev/null || true
            log_success "S3 バケット 削除完了: $bucket"
        else
            echo "  実行コマンド: aws s3 rm s3://$bucket --recursive && aws s3 rb s3://$bucket"
        fi
    done
else
    log_info "S3 バケットはありません。"
fi

# 11. CloudWatch Alarms の削除
print_header "11. CloudWatch Alarms 削除"

alarms=$(aws cloudwatch describe-alarms --region $REGION \
  --query 'MetricAlarms[*].AlarmName' --output text 2>/dev/null || echo "")

if [ -n "$alarms" ]; then
    for alarm in $alarms; do
        execute_cmd "aws cloudwatch delete-alarms --alarm-names \"$alarm\" --region $REGION" \
            "CloudWatch Alarm 削除: $alarm"
    done
else
    log_info "CloudWatch Alarms はありません。"
fi

# 12. CloudWatch Log Groups の削除
print_header "12. CloudWatch Log Groups 削除"

log_groups=$(aws logs describe-log-groups --region $REGION \
  --query 'logGroups[*].logGroupName' --output text 2>/dev/null || echo "")

if [ -n "$log_groups" ]; then
    for log_group in $log_groups; do
        execute_cmd "aws logs delete-log-group --log-group-name \"$log_group\" --region $REGION" \
            "CloudWatch Log Group 削除: $log_group"
    done
else
    log_info "CloudWatch Log Groups はありません。"
fi

# 13. CloudTrail の削除
print_header "13. CloudTrail 削除"

trails=$(aws cloudtrail describe-trails --region $REGION \
  --query 'trailList[*].Name' --output text 2>/dev/null || echo "")

if [ -n "$trails" ]; then
    for trail in $trails; do
        execute_cmd "aws cloudtrail delete-trail --name \"$trail\" --region $REGION" \
            "CloudTrail 削除: $trail"
    done
else
    log_info "CloudTrail はありません。"
fi

# 14. IAM グループの削除
print_header "14. IAM グループ 削除"

iam_groups=$(aws iam list-groups --query 'Groups[*].GroupName' --output text 2>/dev/null || echo "")

if [ -n "$iam_groups" ]; then
    for group in $iam_groups; do
        log_action "IAM グループ 削除: $group"
        
        if [ "$MODE" = "--execute" ]; then
            # グループメンバー削除
            aws iam get-group --group-name "$group" --query 'Users[*].UserName' --output text 2>/dev/null | \
              while read user; do
                [ -n "$user" ] && aws iam remove-user-from-group --group-name "$group" --user-name "$user" 2>/dev/null || true
              done
            
            # ポリシー削除
            aws iam list-attached-group-policies --group-name "$group" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null | \
              while read policy_arn; do
                [ -n "$policy_arn" ] && aws iam detach-group-policy --group-name "$group" --policy-arn "$policy_arn" 2>/dev/null || true
              done
            
            # グループ削除
            aws iam delete-group --group-name "$group" 2>/dev/null || true
            log_success "IAM グループ 削除完了: $group"
        else
            echo "  実行コマンド: aws iam delete-group --group-name \"$group\""
        fi
    done
else
    log_info "IAM グループはありません。"
fi

# 完了メッセージ
print_header "削除処理 完了"

if [ "$MODE" = "--dry-run" ]; then
    log_info "ドライランモード: 削除は実行されませんでした。"
    log_info "実際に削除するには以下のコマンドを実行してください:"
    echo ""
    echo "  bash cleanup-aws-resources.sh --execute"
    echo ""
else
    log_success "リソース削除が完了しました。"
    log_info "削除確認コマンド:"
    echo ""
    echo "  aws ec2 describe-instances --region $REGION --filters 'Name=instance-state-name,Values=running,stopped'"
    echo "  aws rds describe-db-instances --region $REGION"
    echo "  aws s3 ls"
    echo ""
fi
