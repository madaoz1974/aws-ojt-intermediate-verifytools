#!/bin/bash

# AWS Resource Verification Script
# 成果物確認ポイントに基づくAWSリソースの検証

# Note: エラーが発生しても検証を継続するため set -e を使用しない

# カラー出力設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ログディレクトリとファイル
LOG_DIR="/workspaces/aws-ojt-intermediate-verifytools/log"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/verification_$(date +%Y%m%d_%H%M%S).log"

# ヘルパー関数
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log_header() {
    echo "" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
    echo "$1" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
}

check_success() {
    if [ $? -eq 0 ]; then
        log "${GREEN}✓ $1${NC}"
    else
        log "${RED}✗ $1${NC}"
        return 1
    fi
}

# 設定ファイルの読み込み
if [ -f "/workspaces/aws-ojt-intermediate-verifytools/config/aws-config.sh" ]; then
    source /workspaces/aws-ojt-intermediate-verifytools/config/aws-config.sh
else
    log "${YELLOW}警告: 設定ファイルが見つかりません。デフォルト値を使用します。${NC}"
fi

# CloudFront検証
verify_cloudfront() {
    log_header "CloudFront 検証"
    
    if [ -z "$CLOUDFRONT_DISTRIBUTION_ID" ]; then
        log "${YELLOW}CloudFront Distribution IDが設定されていません。スキップします。${NC}"
        return 0
    fi
    
    log "CloudFront Distribution: $CLOUDFRONT_DISTRIBUTION_ID"
    
    # Distribution情報取得
    local distribution_info=$(aws cloudfront get-distribution --id "$CLOUDFRONT_DISTRIBUTION_ID" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "${RED}✗ CloudFront Distribution が見つかりません${NC}"
        return 1
    fi
    
    # 基本情報確認
    local default_root_object=$(echo "$distribution_info" | jq -r '.Distribution.DistributionConfig.DefaultRootObject')
    local origins=$(echo "$distribution_info" | jq -r '.Distribution.DistributionConfig.Origins.Items[].DomainName')
    
    log "Default Root Object: $default_root_object"
    log "Origins: $origins"
    
    # Cache Behaviors確認（現在はApp用構成のため、LP用は将来対応）
    local behaviors=$(echo "$distribution_info" | jq -r '.Distribution.DistributionConfig.CacheBehaviors.Items[]?.PathPattern // empty')
    if echo "$behaviors" | grep -q "/contents/*"; then
        log "${GREEN}✓ /contents/ パスルーティングが設定されています（LP用S3対応済み）${NC}"
    else
        log "${BLUE}i /contents/ パスルーティング未設定（現在はApp用構成のため正常）${NC}"
        log "${BLUE}  ※ LP用S3作成時に /contents/* → LP用S3 のルーティングを追加予定${NC}"
    fi
    
    # Distribution状態確認
    local status=$(echo "$distribution_info" | jq -r '.Distribution.Status')
    if [ "$status" = "Deployed" ]; then
        check_success "CloudFront Distribution が正常にデプロイされています"
    else
        log "${YELLOW}⚠ CloudFront Distribution 状態: $status${NC}"
    fi
}

# ALB検証
verify_alb() {
    log_header "Application Load Balancer 検証"
    
    if [ -z "$ALB_ARN" ]; then
        log "${YELLOW}ALB ARNが設定されていません。名前で検索を試みます。${NC}"
        if [ -n "$ALB_NAME" ]; then
            ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
        fi
    fi
    
    if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
        log "${RED}✗ ALBが見つかりません${NC}"
        return 1
    fi
    
    log "ALB ARN: $ALB_ARN"
    
    # Target Groups取得
    local target_groups=$(aws elbv2 describe-target-groups --load-balancer-arn "$ALB_ARN" --query 'TargetGroups[*].TargetGroupArn' --output text)
    
    for tg_arn in $target_groups; do
        log "Target Group: $tg_arn"
        
        # Health Check設定確認
        local health_check=$(aws elbv2 describe-target-groups --target-group-arns "$tg_arn")
        local health_check_path=$(echo "$health_check" | jq -r '.TargetGroups[0].HealthCheckPath')
        local health_check_port=$(echo "$health_check" | jq -r '.TargetGroups[0].HealthCheckPort')
        local health_check_protocol=$(echo "$health_check" | jq -r '.TargetGroups[0].HealthCheckProtocol')
        
        log "  Health Check Path: $health_check_path"
        log "  Health Check Port: $health_check_port"
        log "  Health Check Protocol: $health_check_protocol"
        
        # Target Health確認
        local target_health=$(aws elbv2 describe-target-health --target-group-arn "$tg_arn")
        local healthy_targets=$(echo "$target_health" | jq -r '.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy") | .Target.Id' | wc -l)
        local total_targets=$(echo "$target_health" | jq -r '.TargetHealthDescriptions[].Target.Id' | wc -l)
        
        if [ "$healthy_targets" -gt 0 ] && [ "$healthy_targets" -eq "$total_targets" ]; then
            check_success "全てのターゲット ($healthy_targets/$total_targets) が正常です"
        else
            log "${YELLOW}⚠ 正常なターゲット: $healthy_targets/$total_targets${NC}"
            echo "$target_health" | jq -r '.TargetHealthDescriptions[] | "\(.Target.Id): \(.TargetHealth.State) - \(.TargetHealth.Description)"' | tee -a "$LOG_FILE"
        fi
    done
}

# EC2検証
verify_ec2() {
    log_header "EC2 インスタンス検証"
    
    # EC2インスタンス一覧取得
    local instances=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name,IamInstanceProfile.Arn]' --output table)
    
    log "実行中のEC2インスタンス:"
    echo "$instances" | tee -a "$LOG_FILE"
    
    # 各インスタンスの詳細確認
    local instance_ids=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query 'Reservations[*].Instances[*].InstanceId' --output text)
    
    for instance_id in $instance_ids; do
        log "インスタンス ID: $instance_id"
        
        # IAM Role確認
        local iam_profile=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        if [ "$iam_profile" != "None" ] && [ -n "$iam_profile" ]; then
            check_success "IAM Instance Profile が設定されています: $iam_profile"
            
            # Role名取得してポリシー確認
            local role_name=$(echo "$iam_profile" | sed 's|.*/||')
            local attached_policies=$(aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[*].PolicyName' --output text 2>/dev/null)
            log "  アタッチされたポリシー: $attached_policies"
        else
            log "${RED}✗ IAM Instance Profile が設定されていません${NC}"
        fi
        
        # Security Group確認
        local security_groups=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].SecurityGroups[*].GroupId' --output text)
        log "  Security Groups: $security_groups"
        
        # SSM接続可能性確認（Session Manager Plugin必要）
        if command -v session-manager-plugin >/dev/null 2>&1; then
            local ssm_status=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$instance_id" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
            if [ "$ssm_status" = "Online" ]; then
                check_success "SSM Agent がオンラインです"
            else
                log "${YELLOW}⚠ SSM Agent 状態: $ssm_status${NC}"
            fi
        fi
    done
}

# Security Group検証
verify_security_groups() {
    log_header "Security Group 検証"
    
    # 実行中のインスタンスのSG取得
    local instance_sgs=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query 'Reservations[*].Instances[*].SecurityGroups[*].GroupId' --output text | tr '\t' '\n' | sort -u)
    
    # ALBのSG取得
    if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
        local alb_sgs=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].SecurityGroups[*]' --output text)
        log "ALB Security Groups: $alb_sgs"
    fi
    
    # RDSのSG取得
    if [ -n "$RDS_INSTANCE_ID" ]; then
        local rds_sgs=$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" --query 'DBInstances[0].VpcSecurityGroups[*].VpcSecurityGroupId' --output text 2>/dev/null)
        log "RDS Security Groups: $rds_sgs"
    fi
    
    # 各SGの詳細確認
    for sg_id in $instance_sgs; do
        log "Security Group: $sg_id"
        
        # インバウンドルール確認
        local inbound_rules=$(aws ec2 describe-security-groups --group-ids "$sg_id" --query 'SecurityGroups[0].IpPermissions')
        
        # 0.0.0.0/0 からの直接アクセス確認
        local open_rules=$(echo "$inbound_rules" | jq -r '.[] | select(.IpRanges[]?.CidrIp == "0.0.0.0/0") | "\(.IpProtocol):\(.FromPort // "all")-\(.ToPort // "all")"')
        
        if [ -n "$open_rules" ]; then
            log "${YELLOW}⚠ 0.0.0.0/0 からのアクセスが許可されています:${NC}"
            echo "$open_rules" | while read rule; do
                log "  $rule"
            done
        else
            check_success "0.0.0.0/0 からの直接アクセスは制限されています"
        fi
        
        # SG参照の確認
        local sg_references=$(echo "$inbound_rules" | jq -r '.[]?.UserIdGroupPairs[]?.GroupId // empty')
        if [ -n "$sg_references" ]; then
            log "  Security Group 参照: $sg_references"
        fi
    done
}

# RDS検証
verify_rds() {
    log_header "RDS 検証"
    
    if [ -z "$RDS_INSTANCE_ID" ]; then
        log "${YELLOW}RDS Instance IDが設定されていません。スキップします。${NC}"
        return 0
    fi
    
    log "RDS Instance: $RDS_INSTANCE_ID"
    
    # RDSインスタンス情報取得
    local rds_info=$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "${RED}✗ RDS インスタンスが見つかりません${NC}"
        return 1
    fi
    
    # パラメーターグループ確認
    local param_group=$(echo "$rds_info" | jq -r '.DBInstances[0].DBParameterGroups[0].DBParameterGroupName')
    log "Parameter Group: $param_group"
    
    if echo "$param_group" | grep -q "^default\."; then
        log "${YELLOW}⚠ デフォルトパラメーターグループを使用しています${NC}"
    else
        check_success "カスタムパラメーターグループを使用しています"
    fi
    
    # 暗号化設定確認
    local storage_encrypted=$(echo "$rds_info" | jq -r '.DBInstances[0].StorageEncrypted')
    if [ "$storage_encrypted" = "true" ]; then
        check_success "RDS ストレージが暗号化されています"
    else
        log "${RED}✗ RDS ストレージが暗号化されていません${NC}"
    fi
    
    # エンドポイント確認
    local endpoint=$(echo "$rds_info" | jq -r '.DBInstances[0].Endpoint.Address')
    local port=$(echo "$rds_info" | jq -r '.DBInstances[0].Endpoint.Port')
    log "Endpoint: $endpoint:$port"
    
    # データベース接続テスト（PostgreSQL）
    if [ -n "$RDS_USERNAME" ] && [ -n "$RDS_PASSWORD" ]; then
        log "データベース接続テストを実行中..."
        
        export PGPASSWORD="$RDS_PASSWORD"
        if timeout 10 psql -h "$endpoint" -p "$port" -U "$RDS_USERNAME" -d "${RDS_DATABASE:-postgres}" -c '\l' >/dev/null 2>&1; then
            check_success "データベースに接続できました"
            
            # movie データベース確認
            if psql -h "$endpoint" -p "$port" -U "$RDS_USERNAME" -d "${RDS_DATABASE:-postgres}" -t -c "SELECT datname FROM pg_database WHERE datname='movie';" 2>/dev/null | grep -q movie; then
                check_success "movie データベースが存在します"
            else
                log "${YELLOW}⚠ movie データベースが見つかりません${NC}"
            fi
        else
            log "${RED}✗ データベースに接続できません${NC}"
        fi
        unset PGPASSWORD
    else
        log "${YELLOW}RDS認証情報が設定されていないため、接続テストをスキップします。${NC}"
    fi
}

# S3検証
verify_s3() {
    log_header "S3 検証"
    
    if [ -z "$S3_BUCKET_NAME" ]; then
        log "${YELLOW}S3バケット名が設定されていません。スキップします。${NC}"
        return 0
    fi
    
    log "S3 Bucket: $S3_BUCKET_NAME"
    log "${BLUE}  用途: EC2動画保存用S3（App環境用）${NC}"
    
    # バケット存在確認
    if ! aws s3api head-bucket --bucket "$S3_BUCKET_NAME" 2>/dev/null; then
        log "${RED}✗ S3バケットにアクセスできません${NC}"
        return 1
    fi
    
    # 暗号化設定確認
    local encryption=$(aws s3api get-bucket-encryption --bucket "$S3_BUCKET_NAME" 2>/dev/null)
    if [ $? -eq 0 ]; then
        check_success "S3バケットが暗号化されています"
        local kms_key=$(echo "$encryption" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID // "AES256"')
        log "  暗号化方式: $kms_key"
    else
        log "${RED}✗ S3バケットが暗号化されていません${NC}"
    fi
    
    # バケットポリシー確認
    local bucket_policy=$(aws s3api get-bucket-policy --bucket "$S3_BUCKET_NAME" --output text 2>/dev/null)
    if [ $? -eq 0 ]; then
        log "バケットポリシーが設定されています"
        
        # CloudFrontおよびEC2 Roleのアクセス許可確認
        if echo "$bucket_policy" | grep -q "cloudfront\|OAC\|OriginAccessControl"; then
            log "${BLUE}i CloudFront (OAC) のアクセスが設定されています${NC}"
            log "${BLUE}  ※ 現在はApp用構成のため、LP用S3作成時にCloudFront設定を追加予定${NC}"
        else
            log "${BLUE}i CloudFront (OAC) のアクセス未設定（現在のApp用構成では不要）${NC}"
        fi
        
        if echo "$bucket_policy" | grep -q "arn:aws:iam::.*:role"; then
            check_success "EC2 Role のアクセスが設定されています（動画保存用）"
        else
            log "${YELLOW}⚠ EC2 Role のアクセス設定が明確ではありません${NC}"
            log "${YELLOW}  ※ EC2からの動画ファイル保存のため、Role設定を確認してください${NC}"
        fi
    else
        log "${YELLOW}⚠ バケットポリシーが設定されていません${NC}"
    fi
}

# 暗号化検証
verify_encryption() {
    log_header "暗号化設定検証"
    
    # EBS暗号化確認
    log "EBS暗号化設定確認:"
    local volumes=$(aws ec2 describe-volumes --filters "Name=state,Values=in-use" --query 'Volumes[*].[VolumeId,Encrypted,KmsKeyId]' --output table)
    echo "$volumes" | tee -a "$LOG_FILE"
    
    local unencrypted_volumes=$(aws ec2 describe-volumes --filters "Name=state,Values=in-use" "Name=encrypted,Values=false" --query 'Volumes[*].VolumeId' --output text)
    if [ -n "$unencrypted_volumes" ]; then
        log "${RED}✗ 暗号化されていないEBSボリューム: $unencrypted_volumes${NC}"
    else
        check_success "全てのEBSボリュームが暗号化されています"
    fi
    
    # RDS暗号化は verify_rds() で確認済み
    # S3暗号化は verify_s3() で確認済み
}

# 正常性確認
verify_application_health() {
    log_header "アプリケーション正常性確認"
    
    if [ -n "$CLOUDFRONT_DOMAIN" ]; then
        log "CloudFront ドメイン: $CLOUDFRONT_DOMAIN"
        
        # HTTP/HTTPS接続テスト
        if curl -s --max-time 10 "https://$CLOUDFRONT_DOMAIN" >/dev/null 2>&1; then
            check_success "CloudFront ドメインにHTTPS接続できます"
        else
            log "${RED}✗ CloudFront ドメインにHTTPS接続できません${NC}"
        fi
        
        # Tomcatの動作確認（具体的なパスが分かる場合）
        local tomcat_paths="/contents/movie /movie /app"
        for path in $tomcat_paths; do
            if curl -s --max-time 10 "https://$CLOUDFRONT_DOMAIN$path" | grep -q -i "tomcat\|java\|servlet" 2>/dev/null; then
                check_success "Tomcatアプリケーションが動作しています ($path)"
                break
            fi
        done
    else
        log "${YELLOW}CloudFront ドメインが設定されていません。正常性確認をスキップします。${NC}"
    fi
}

# Operation（運用）構築検証
verify_operation() {
    log_header "Operation（運用）構築検証"
    
    # AWS Backup検証
    log "AWS Backup プラン検証:"
    
    local backup_plans=$(aws backup list-backup-plans 2>/dev/null)
    if [ $? -eq 0 ]; then
        local plan_count=$(echo "$backup_plans" | jq -r '.BackupPlansList | length')
        
        if [ "$plan_count" -gt 0 ]; then
            check_success "AWS Backupプランが作成されています（$plan_count 個）"
            
            echo "$backup_plans" | jq -r '.BackupPlansList[] | "  - \(.BackupPlanName) (作成日: \(.CreationDate))"' | tee -a "$LOG_FILE"
            
            # 各バックアッププランの詳細確認
            echo "$backup_plans" | jq -r '.BackupPlansList[].BackupPlanId' | while read plan_id; do
                local plan_details=$(aws backup get-backup-plan --backup-plan-id "$plan_id" 2>/dev/null)
                
                if [ $? -eq 0 ]; then
                    local plan_name=$(echo "$plan_details" | jq -r '.BackupPlan.BackupPlanName')
                    log "  プラン: $plan_name"
                    
                    # ルール確認
                    local rules=$(echo "$plan_details" | jq -r '.BackupPlan.Rules[]')
                    local rule_count=$(echo "$plan_details" | jq -r '.BackupPlan.Rules | length')
                    log "    ルール数: $rule_count"
                    
                    # 各ルールの詳細
                    echo "$plan_details" | jq -r '.BackupPlan.Rules[] | "    - \(.RuleName): スケジュール=\(.ScheduleExpression // "未設定")"' | tee -a "$LOG_FILE"
                    
                    # 保持期間確認（7世代保存の確認）
                    local lifecycle_days=$(echo "$plan_details" | jq -r '.BackupPlan.Rules[].Lifecycle.DeleteAfterDays // empty')
                    if [ -n "$lifecycle_days" ]; then
                        log "    保持期間: $lifecycle_days 日"
                        
                        # 7世代保存の概算確認（日次バックアップで7日 = 7世代）
                        if [ "$lifecycle_days" -ge 7 ]; then
                            check_success "    7世代以上の保存が設定されています"
                        else
                            log "${YELLOW}    ⚠ 保持期間が7日未満です（推奨: 7世代保存）${NC}"
                        fi
                    else
                        log "${YELLOW}    ⚠ 保持期間が設定されていません${NC}"
                    fi
                fi
            done
            
            # バックアップ選択（リソース割り当て）の確認
            echo "$backup_plans" | jq -r '.BackupPlansList[].BackupPlanId' | while read plan_id; do
                local selections=$(aws backup list-backup-selections --backup-plan-id "$plan_id" 2>/dev/null)
                local selection_count=$(echo "$selections" | jq -r '.BackupSelectionsList | length')
                
                if [ "$selection_count" -gt 0 ]; then
                    local plan_name=$(echo "$backup_plans" | jq -r --arg pid "$plan_id" '.BackupPlansList[] | select(.BackupPlanId == $pid) | .BackupPlanName')
                    log "  $plan_name のリソース割り当て: $selection_count 個"
                    
                    echo "$selections" | jq -r '.BackupSelectionsList[].SelectionName' | while read selection_name; do
                        log "    - $selection_name"
                    done
                else
                    log "${YELLOW}  ⚠ リソースが割り当てられていません${NC}"
                fi
            done
            
            # 最近のバックアップジョブ確認
            local recent_jobs=$(aws backup list-backup-jobs --max-results 5 2>/dev/null)
            if [ $? -eq 0 ]; then
                local job_count=$(echo "$recent_jobs" | jq -r '.BackupJobs | length')
                
                if [ "$job_count" -gt 0 ]; then
                    log "  最近のバックアップジョブ:"
                    echo "$recent_jobs" | jq -r '.BackupJobs[] | "    - \(.ResourceType): \(.State) (作成: \(.CreationDate))"' | head -5 | tee -a "$LOG_FILE"
                    
                    # 失敗したジョブの確認
                    local failed_jobs=$(echo "$recent_jobs" | jq -r '.BackupJobs[] | select(.State == "FAILED") | .BackupJobId')
                    if [ -n "$failed_jobs" ]; then
                        log "${RED}  ✗ 失敗したバックアップジョブがあります${NC}"
                    fi
                fi
            fi
        else
            log "${YELLOW}⚠ AWS Backupプランが作成されていません${NC}"
            log "${YELLOW}  対処: EC2/RDSの7世代バックアップ用にBackupプランを作成してください${NC}"
        fi
    fi
    
    # EventBridge（平日日中のみ起動）検証
    log ""
    log "EventBridge ルール検証（平日日中起動制御）:"
    
    local eventbridge_rules=$(aws events list-rules 2>/dev/null)
    if [ $? -eq 0 ]; then
        local rule_count=$(echo "$eventbridge_rules" | jq -r '.Rules | length')
        
        if [ "$rule_count" -gt 0 ]; then
            check_success "EventBridgeルールが設定されています（$rule_count 個）"
            
            # EC2起動/停止ルールの確認
            local has_start_rule=false
            local has_stop_rule=false
            
            echo "$eventbridge_rules" | jq -r '.Rules[] | "\(.Name): \(.State) (スケジュール: \(.ScheduleExpression // "イベントパターン"))"' | tee -a "$LOG_FILE" | while read rule_info; do
                log "  - $rule_info"
                
                if echo "$rule_info" | grep -qi "start\|起動"; then
                    has_start_rule=true
                fi
                
                if echo "$rule_info" | grep -qi "stop\|停止"; then
                    has_stop_rule=true
                fi
            done
            
            # 詳細確認
            echo "$eventbridge_rules" | jq -r '.Rules[].Name' | while read rule_name; do
                local rule_details=$(aws events describe-rule --name "$rule_name" 2>/dev/null)
                
                if [ $? -eq 0 ]; then
                    local schedule=$(echo "$rule_details" | jq -r '.ScheduleExpression // empty')
                    local state=$(echo "$rule_details" | jq -r '.State')
                    
                    # 平日のみのスケジュール確認（cron式で月-金を確認）
                    if echo "$schedule" | grep -qi "cron"; then
                        if echo "$schedule" | grep -qi "MON-FRI\|1-5"; then
                            check_success "  $rule_name: 平日スケジュールが設定されています"
                            log "    スケジュール: $schedule"
                        fi
                    fi
                    
                    # ルールの状態確認
                    if [ "$state" = "ENABLED" ]; then
                        log "    状態: 有効"
                    else
                        log "${YELLOW}    ⚠ 状態: 無効${NC}"
                    fi
                    
                    # ターゲット確認
                    local targets=$(aws events list-targets-by-rule --rule "$rule_name" 2>/dev/null)
                    local target_count=$(echo "$targets" | jq -r '.Targets | length')
                    
                    if [ "$target_count" -gt 0 ]; then
                        log "    ターゲット: $target_count 個"
                        
                        # EC2インスタンスIDの確認
                        echo "$targets" | jq -r '.Targets[].Id' | while read target_id; do
                            if [[ "$target_id" =~ ^i- ]]; then
                                log "      - EC2: $target_id"
                            fi
                        done
                    fi
                fi
            done
        else
            log "${YELLOW}⚠ EventBridgeルールが設定されていません${NC}"
            log "${YELLOW}  対処: EC2の平日日中起動制御用にEventBridgeルールを作成してください${NC}"
        fi
    fi
    
    # RDS/EC2メンテナンスウィンドウ確認
    log ""
    log "メンテナンスウィンドウ設定確認:"
    
    # RDSメンテナンスウィンドウ
    if [ -n "$RDS_INSTANCE_ID" ]; then
        local rds_info=$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            local maintenance_window=$(echo "$rds_info" | jq -r '.DBInstances[0].PreferredMaintenanceWindow')
            local backup_window=$(echo "$rds_info" | jq -r '.DBInstances[0].PreferredBackupWindow')
            
            log "  RDS ($RDS_INSTANCE_ID):"
            log "    メンテナンスウィンドウ: $maintenance_window"
            log "    バックアップウィンドウ: $backup_window"
            
            # 0時～4時のメンテナンス時間を確認
            if echo "$maintenance_window" | grep -qi "00:\|01:\|02:\|03:"; then
                check_success "    深夜帯（0時～4時）にメンテナンスウィンドウが設定されています"
            else
                log "${YELLOW}    ⚠ メンテナンスウィンドウが深夜帯以外です（推奨: 0時～4時）${NC}"
            fi
        fi
    fi
    
    # AWS Inspector検証
    log ""
    log "AWS Inspector 設定確認:"
    
    # Inspector v2を使用
    local inspector_status=$(aws inspector2 batch-get-account-status --account-ids "$(aws sts get-caller-identity --query Account --output text)" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local ec2_status=$(echo "$inspector_status" | jq -r '.accounts[0].resourceState.ec2.status // "DISABLED"')
        local ecr_status=$(echo "$inspector_status" | jq -r '.accounts[0].resourceState.ecr.status // "DISABLED"')
        local lambda_status=$(echo "$inspector_status" | jq -r '.accounts[0].resourceState.lambda.status // "DISABLED"')
        
        log "  Inspector v2 状態:"
        log "    EC2スキャン: $ec2_status"
        log "    ECRスキャン: $ecr_status"
        log "    Lambdaスキャン: $lambda_status"
        
        if [ "$ec2_status" = "ENABLED" ]; then
            check_success "  EC2の脆弱性スキャンが有効です"
            
            # 検出結果の確認
            local findings=$(aws inspector2 list-findings --filter-criteria '{"resourceType":[{"comparison":"EQUALS","value":"AWS_EC2_INSTANCE"}]}' --max-results 10 2>/dev/null)
            
            if [ $? -eq 0 ]; then
                local finding_count=$(echo "$findings" | jq -r '.findings | length')
                
                if [ "$finding_count" -gt 0 ]; then
                    log "    最近の検出結果: $finding_count 件"
                    
                    # 重大度別カウント
                    local critical=$(echo "$findings" | jq -r '.findings[] | select(.severity == "CRITICAL") | .findingArn' | wc -l)
                    local high=$(echo "$findings" | jq -r '.findings[] | select(.severity == "HIGH") | .findingArn' | wc -l)
                    local medium=$(echo "$findings" | jq -r '.findings[] | select(.severity == "MEDIUM") | .findingArn' | wc -l)
                    
                    if [ "$critical" -gt 0 ] || [ "$high" -gt 0 ]; then
                        log "${RED}    ✗ 重要な脆弱性が検出されています（Critical: $critical, High: $high, Medium: $medium）${NC}"
                    else
                        log "    検出された脆弱性: Medium: $medium, その他"
                    fi
                else
                    check_success "    脆弱性は検出されていません"
                fi
            fi
        else
            log "${YELLOW}  ⚠ EC2の脆弱性スキャンが無効です${NC}"
            log "${YELLOW}    対処: AWS Inspector v2でEC2スキャンを有効化してください${NC}"
        fi
    else
        log "${YELLOW}⚠ AWS Inspector の状態を取得できません${NC}"
        log "${YELLOW}  対処: AWS Inspector v2を有効化してください${NC}"
    fi
    
    # コスト管理（予算アラート）検証
    log ""
    log "コスト管理（予算アラート）検証:"
    
    local budgets=$(aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local budget_count=$(echo "$budgets" | jq -r '.Budgets | length')
        
        if [ "$budget_count" -gt 0 ]; then
            check_success "予算が設定されています（$budget_count 個）"
            
            echo "$budgets" | jq -r '.Budgets[] | "  - \(.BudgetName): \(.BudgetLimit.Amount) \(.BudgetLimit.Unit) (\(.TimeUnit))"' | tee -a "$LOG_FILE"
            
            # 月額7万円以下の確認
            local monthly_budget=$(echo "$budgets" | jq -r '.Budgets[] | select(.TimeUnit == "MONTHLY") | .BudgetLimit.Amount' | head -1)
            
            if [ -n "$monthly_budget" ]; then
                local budget_value=${monthly_budget%.*}  # 小数点以下切り捨て
                
                if [ "$budget_value" -le 70000 ]; then
                    check_success "  月額予算が70,000円以下に設定されています（$monthly_budget 円）"
                else
                    log "${YELLOW}  ⚠ 月額予算が70,000円を超えています（$monthly_budget 円）${NC}"
                fi
            fi
            
            # 予算通知の確認
            echo "$budgets" | jq -r '.Budgets[].BudgetName' | while read budget_name; do
                local notifications=$(aws budgets describe-notifications-for-budget \
                    --account-id "$(aws sts get-caller-identity --query Account --output text)" \
                    --budget-name "$budget_name" 2>/dev/null)
                
                if [ $? -eq 0 ]; then
                    local notification_count=$(echo "$notifications" | jq -r '.Notifications | length')
                    
                    if [ "$notification_count" -gt 0 ]; then
                        check_success "  $budget_name: 通知が設定されています（$notification_count 件）"
                        
                        # 通知の閾値確認
                        echo "$notifications" | jq -r '.Notifications[] | "    - \(.NotificationType): \(.Threshold)% (\(.ComparisonOperator))"' | tee -a "$LOG_FILE"
                    else
                        log "${YELLOW}  ⚠ $budget_name: 通知が設定されていません${NC}"
                    fi
                fi
            done
        else
            log "${YELLOW}⚠ 予算が設定されていません${NC}"
            log "${YELLOW}  対処: 月額70,000円以下の予算を設定してください${NC}"
        fi
    else
        log "${YELLOW}⚠ 予算情報を取得できません${NC}"
    fi
    
    # IAM権限管理（部門別権限）検証
    log ""
    log "IAM権限管理（部門別）検証:"
    
    # グループベースの権限管理確認
    local iam_groups=$(aws iam list-groups 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local group_count=$(echo "$iam_groups" | jq -r '.Groups | length')
        
        if [ "$group_count" -gt 0 ]; then
            check_success "IAMグループが作成されています（$group_count 個）"
            
            # 部門別グループの確認
            local has_finance=false
            local has_management=false
            local has_it=false
            
            echo "$iam_groups" | jq -r '.Groups[].GroupName' | while read group_name; do
                log "  - $group_name"
                
                # グループのポリシー確認
                local attached_policies=$(aws iam list-attached-group-policies --group-name "$group_name" 2>/dev/null)
                
                if [ $? -eq 0 ]; then
                    local policy_count=$(echo "$attached_policies" | jq -r '.AttachedPolicies | length')
                    
                    if [ "$policy_count" -gt 0 ]; then
                        log "    アタッチされたポリシー: $policy_count 個"
                        echo "$attached_policies" | jq -r '.AttachedPolicies[].PolicyName' | while read policy_name; do
                            log "      - $policy_name"
                        done
                    fi
                fi
                
                # 部門別の確認
                if echo "$group_name" | grep -qi "finance\|経理\|keiri"; then
                    has_finance=true
                    log "    ${GREEN}✓ 経理部門グループを検出${NC}"
                    
                    # コスト関連ポリシーの確認
                    if echo "$attached_policies" | jq -r '.AttachedPolicies[].PolicyName' | grep -qi "billing\|cost\|budget"; then
                        check_success "      コスト関連ポリシーが割り当てられています"
                    fi
                fi
                
                if echo "$group_name" | grep -qi "management\|admin\|経営\|keiei"; then
                    has_management=true
                    log "    ${GREEN}✓ 経営管理部門グループを検出${NC}"
                    
                    # 管理者権限の確認
                    if echo "$attached_policies" | jq -r '.AttachedPolicies[].PolicyName' | grep -qi "administrator\|admin"; then
                        check_success "      管理者権限が割り当てられています"
                    fi
                fi
                
                if echo "$group_name" | grep -qi "^it\|developer\|engineer"; then
                    has_it=true
                    log "    ${GREEN}✓ IT部門グループを検出${NC}"
                fi
            done
            
            # 推奨グループの確認
            if [ "$has_finance" = false ]; then
                log "${YELLOW}  ⚠ 経理部門用のグループが見つかりません${NC}"
            fi
            
            if [ "$has_management" = false ]; then
                log "${YELLOW}  ⚠ 経営管理部門用のグループが見つかりません${NC}"
            fi
            
            if [ "$has_it" = false ]; then
                log "${YELLOW}  ⚠ IT部門用のグループが見つかりません${NC}"
            fi
        else
            log "${YELLOW}⚠ IAMグループが作成されていません${NC}"
            log "${YELLOW}  対処: 部門別（経理、経営管理、IT）のIAMグループを作成してください${NC}"
        fi
    fi
    
    # コスト配分タグの確認
    log ""
    log "コスト配分タグ確認:"
    
    local cost_tags=$(aws ce list-cost-allocation-tags 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local active_tags=$(echo "$cost_tags" | jq -r '.CostAllocationTags[] | select(.Status == "Active") | .TagKey')
        local active_count=$(echo "$active_tags" | grep -c ".*" || echo "0")
        
        if [ "$active_count" -gt 0 ]; then
            check_success "コスト配分タグが有効化されています（$active_count 個）"
            echo "$active_tags" | while read tag; do
                log "  - $tag"
            done
        else
            log "${YELLOW}⚠ コスト配分タグが有効化されていません${NC}"
            log "${YELLOW}  対処: 部門別コスト管理用にタグを有効化してください${NC}"
        fi
    fi
}

# Monitoring（監視）構築検証
verify_monitoring() {
    log_header "Monitoring（監視）構築検証"
    
    # CloudWatch Alarms検証
    log "CloudWatch Alarms 検証:"
    
    local alarms=$(aws cloudwatch describe-alarms 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "${RED}✗ CloudWatch Alarmsの取得に失敗しました${NC}"
        return 1
    fi
    
    local alarm_count=$(echo "$alarms" | jq -r '.MetricAlarms | length')
    
    if [ "$alarm_count" -gt 0 ]; then
        check_success "CloudWatch Alarmsが設定されています（$alarm_count 個）"
        
        # アラーム詳細の表示
        echo "$alarms" | jq -r '.MetricAlarms[] | "  - \(.AlarmName): \(.StateValue) (\(.MetricName))"' | tee -a "$LOG_FILE"
        
        # 重要なメトリクスの確認
        local has_cpu_alarm=false
        local has_status_check_alarm=false
        local has_rds_alarm=false
        local has_alb_alarm=false
        
        # EC2 CPU使用率アラーム
        if echo "$alarms" | jq -r '.MetricAlarms[].MetricName' | grep -qi "CPUUtilization"; then
            has_cpu_alarm=true
            check_success "CPU使用率のアラームが設定されています"
        fi
        
        # EC2 ステータスチェックアラーム
        if echo "$alarms" | jq -r '.MetricAlarms[].MetricName' | grep -qi "StatusCheck"; then
            has_status_check_alarm=true
            check_success "ステータスチェックのアラームが設定されています"
        fi
        
        # RDS関連アラーム
        if echo "$alarms" | jq -r '.MetricAlarms[].Namespace' | grep -qi "AWS/RDS"; then
            has_rds_alarm=true
            check_success "RDS関連のアラームが設定されています"
            
            # RDSアラームの詳細
            local rds_metrics=$(echo "$alarms" | jq -r '.MetricAlarms[] | select(.Namespace == "AWS/RDS") | .MetricName' | sort -u)
            log "  RDSメトリクス: $(echo "$rds_metrics" | tr '\n' ', ' | sed 's/,$//')"
        fi
        
        # ALB関連アラーム
        if echo "$alarms" | jq -r '.MetricAlarms[].Namespace' | grep -qi "AWS/ApplicationELB"; then
            has_alb_alarm=true
            check_success "ALB関連のアラームが設定されています"
        fi
        
        # 推奨アラームの確認
        if [ "$has_cpu_alarm" = false ]; then
            log "${YELLOW}⚠ CPU使用率のアラームが推奨されます${NC}"
        fi
        
        if [ "$has_status_check_alarm" = false ]; then
            log "${YELLOW}⚠ EC2ステータスチェックのアラームが推奨されます${NC}"
        fi
        
        # アラームアクション（SNS通知）の確認
        local alarms_with_actions=$(echo "$alarms" | jq -r '.MetricAlarms[] | select(.AlarmActions | length > 0) | .AlarmName')
        local action_count=$(echo "$alarms_with_actions" | grep -c ".*" || echo "0")
        
        if [ "$action_count" -gt 0 ]; then
            check_success "アラームアクション（通知）が設定されています（$action_count 個）"
        else
            log "${YELLOW}⚠ アラームアクションが設定されていません${NC}"
            log "${YELLOW}  対処: SNSトピックをアラームアクションに追加してください${NC}"
        fi
        
    else
        log "${YELLOW}⚠ CloudWatch Alarmsが設定されていません${NC}"
        log "${YELLOW}  対処: EC2、RDS、ALBなどのメトリクスにアラームを設定してください${NC}"
    fi
    
    # SNS Topics検証
    log ""
    log "SNS Topics 検証:"
    
    local sns_topics=$(aws sns list-topics 2>/dev/null)
    if [ $? -eq 0 ]; then
        local topic_count=$(echo "$sns_topics" | jq -r '.Topics | length')
        
        if [ "$topic_count" -gt 0 ]; then
            check_success "SNS Topicsが作成されています（$topic_count 個）"
            
            # 各トピックの詳細確認
            echo "$sns_topics" | jq -r '.Topics[].TopicArn' | while read topic_arn; do
                local topic_name=$(echo "$topic_arn" | awk -F: '{print $NF}')
                log "  Topic: $topic_name"
                
                # サブスクリプション確認
                local subscriptions=$(aws sns list-subscriptions-by-topic --topic-arn "$topic_arn" 2>/dev/null)
                local sub_count=$(echo "$subscriptions" | jq -r '.Subscriptions | length')
                
                if [ "$sub_count" -gt 0 ]; then
                    log "    サブスクリプション: $sub_count 個"
                    
                    # メールサブスクリプションの確認
                    local email_subs=$(echo "$subscriptions" | jq -r '.Subscriptions[] | select(.Protocol == "email") | .Endpoint')
                    if [ -n "$email_subs" ]; then
                        check_success "    メール通知が設定されています"
                        echo "$email_subs" | while read email; do
                            log "      - $email"
                        done
                    fi
                    
                    # サブスクリプションの状態確認
                    local pending_subs=$(echo "$subscriptions" | jq -r '.Subscriptions[] | select(.SubscriptionArn == "PendingConfirmation") | .Endpoint')
                    if [ -n "$pending_subs" ]; then
                        log "${YELLOW}    ⚠ 確認待ちのサブスクリプションがあります:${NC}"
                        echo "$pending_subs" | while read endpoint; do
                            log "${YELLOW}      - $endpoint${NC}"
                        done
                    fi
                else
                    log "${YELLOW}    ⚠ サブスクリプションが設定されていません${NC}"
                fi
            done
        else
            log "${YELLOW}⚠ SNS Topicsが作成されていません${NC}"
            log "${YELLOW}  対処: アラーム通知用のSNS Topicを作成してください${NC}"
        fi
    fi
    
    # CloudWatch Dashboards検証
    log ""
    log "CloudWatch Dashboards 検証:"
    
    local dashboards=$(aws cloudwatch list-dashboards 2>/dev/null)
    if [ $? -eq 0 ]; then
        local dashboard_count=$(echo "$dashboards" | jq -r '.DashboardEntries | length')
        
        if [ "$dashboard_count" -gt 0 ]; then
            check_success "CloudWatch Dashboardsが作成されています（$dashboard_count 個）"
            
            echo "$dashboards" | jq -r '.DashboardEntries[] | "  - \(.DashboardName) (最終更新: \(.LastModified))"' | tee -a "$LOG_FILE"
            
            # ダッシュボードの詳細確認
            echo "$dashboards" | jq -r '.DashboardEntries[].DashboardName' | while read dashboard_name; do
                local dashboard_body=$(aws cloudwatch get-dashboard --dashboard-name "$dashboard_name" 2>/dev/null)
                
                if [ $? -eq 0 ]; then
                    local widget_count=$(echo "$dashboard_body" | jq -r '.DashboardBody' | jq -r '.widgets | length')
                    log "    $dashboard_name: $widget_count ウィジェット"
                fi
            done
        else
            log "${YELLOW}⚠ CloudWatch Dashboardsが作成されていません${NC}"
            log "${YELLOW}  対処: システム監視用のダッシュボードを作成してください${NC}"
        fi
    fi
    
    # CloudWatch Logs検証
    log ""
    log "CloudWatch Logs 検証:"
    
    local log_groups=$(aws logs describe-log-groups 2>/dev/null)
    if [ $? -eq 0 ]; then
        local log_group_count=$(echo "$log_groups" | jq -r '.logGroups | length')
        
        if [ "$log_group_count" -gt 0 ]; then
            check_success "CloudWatch Log Groupsが作成されています（$log_group_count 個）"
            
            # 主要なログの確認
            local has_ec2_logs=false
            local has_rds_logs=false
            local has_codebuild_logs=false
            
            echo "$log_groups" | jq -r '.logGroups[].logGroupName' | while read log_group_name; do
                log "  - $log_group_name"
                
                # ログの保持期間確認
                local retention=$(echo "$log_groups" | jq -r --arg lgn "$log_group_name" '.logGroups[] | select(.logGroupName == $lgn) | .retentionInDays // "無期限"')
                log "    保持期間: $retention"
            done
            
            # EC2/アプリケーションログの確認
            if echo "$log_groups" | jq -r '.logGroups[].logGroupName' | grep -qi "ec2\|application\|tomcat"; then
                check_success "アプリケーションログが設定されています"
            fi
            
            # RDSログの確認
            if echo "$log_groups" | jq -r '.logGroups[].logGroupName' | grep -qi "rds\|database"; then
                check_success "RDSログが設定されています"
            fi
            
            # CodeBuildログの確認
            if echo "$log_groups" | jq -r '.logGroups[].logGroupName' | grep -qi "codebuild"; then
                check_success "CodeBuildログが設定されています"
            fi
        else
            log "${YELLOW}⚠ CloudWatch Log Groupsが作成されていません${NC}"
            log "${YELLOW}  対処: アプリケーションログをCloudWatch Logsに送信してください${NC}"
        fi
    fi
    
    # CloudTrail検証
    log ""
    log "CloudTrail 検証:"
    
    local trails=$(aws cloudtrail describe-trails 2>/dev/null)
    if [ $? -eq 0 ]; then
        local trail_count=$(echo "$trails" | jq -r '.trailList | length')
        
        if [ "$trail_count" -gt 0 ]; then
            check_success "CloudTrailが設定されています（$trail_count 個）"
            
            echo "$trails" | jq -r '.trailList[] | "  - \(.Name) (S3: \(.S3BucketName))"' | tee -a "$LOG_FILE"
            
            # Trail の状態確認
            echo "$trails" | jq -r '.trailList[].Name' | while read trail_name; do
                local trail_status=$(aws cloudtrail get-trail-status --name "$trail_name" 2>/dev/null)
                
                if [ $? -eq 0 ]; then
                    local is_logging=$(echo "$trail_status" | jq -r '.IsLogging')
                    
                    if [ "$is_logging" = "true" ]; then
                        check_success "  $trail_name: ログ記録中"
                    else
                        log "${RED}✗ $trail_name: ログ記録が停止しています${NC}"
                    fi
                fi
            done
            
            # S3へのログ保存確認
            local s3_buckets=$(echo "$trails" | jq -r '.trailList[].S3BucketName' | sort -u)
            if [ -n "$s3_buckets" ]; then
                check_success "S3へのログ保存が設定されています"
                echo "$s3_buckets" | while read bucket; do
                    log "    バケット: $bucket"
                    
                    # バケットの暗号化確認
                    local encryption=$(aws s3api get-bucket-encryption --bucket "$bucket" 2>/dev/null)
                    if [ $? -eq 0 ]; then
                        check_success "    $bucket: 暗号化されています"
                    else
                        log "${YELLOW}    ⚠ $bucket: 暗号化が設定されていません${NC}"
                    fi
                done
            fi
        else
            log "${YELLOW}⚠ CloudTrailが設定されていません${NC}"
            log "${YELLOW}  対処: API操作の監査ログ用にCloudTrailを設定してください${NC}"
        fi
    fi
    
    # メトリクスフィルター検証（特定のログパターンの監視）
    log ""
    log "CloudWatch メトリクスフィルター 検証:"
    
    if [ "$log_group_count" -gt 0 ]; then
        local total_filters=0
        
        echo "$log_groups" | jq -r '.logGroups[].logGroupName' | while read log_group_name; do
            local filters=$(aws logs describe-metric-filters --log-group-name "$log_group_name" 2>/dev/null)
            
            if [ $? -eq 0 ]; then
                local filter_count=$(echo "$filters" | jq -r '.metricFilters | length')
                
                if [ "$filter_count" -gt 0 ]; then
                    log "  $log_group_name: $filter_count フィルター"
                    total_filters=$((total_filters + filter_count))
                fi
            fi
        done
        
        if [ "$total_filters" -gt 0 ]; then
            check_success "メトリクスフィルターが設定されています（合計: $total_filters 個）"
        else
            log "${YELLOW}⚠ メトリクスフィルターが設定されていません${NC}"
            log "${YELLOW}  対処: エラーログの監視用にメトリクスフィルターを設定してください${NC}"
        fi
    fi
}

# CI/CD構築検証
verify_cicd() {
    log_header "CI/CD構築検証"
    
    # CodePipeline検証
    if [ -z "$CODEPIPELINE_NAME" ]; then
        log "${YELLOW}CodePipeline名が設定されていません。スキップします。${NC}"
        log "${BLUE}i 設定ファイルに CODEPIPELINE_NAME を追加してください${NC}"
        return 0
    fi
    
    log "CodePipeline: $CODEPIPELINE_NAME"
    
    # Pipeline存在確認
    local pipeline_info=$(aws codepipeline get-pipeline --name "$CODEPIPELINE_NAME" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "${RED}✗ CodePipelineが見つかりません${NC}"
        return 1
    fi
    check_success "CodePipelineが存在します"
    
    # Pipeline状態確認
    local pipeline_state=$(aws codepipeline get-pipeline-state --name "$CODEPIPELINE_NAME" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local stage_count=$(echo "$pipeline_state" | jq -r '.stageStates | length')
        log "  パイプラインステージ数: $stage_count"
        
        # 各ステージの状態確認
        echo "$pipeline_state" | jq -r '.stageStates[] | "\(.stageName): \(.latestExecution.status // "未実行")"' | while read stage_info; do
            log "  $stage_info"
        done
        
        # 最新の実行状態確認
        local latest_execution=$(aws codepipeline list-pipeline-executions --pipeline-name "$CODEPIPELINE_NAME" --max-items 1 2>/dev/null)
        if [ $? -eq 0 ]; then
            local execution_status=$(echo "$latest_execution" | jq -r '.pipelineExecutionSummaries[0].status // "None"')
            local last_update=$(echo "$latest_execution" | jq -r '.pipelineExecutionSummaries[0].lastUpdateTime // "Unknown"')
            
            case "$execution_status" in
                "Succeeded")
                    check_success "最新のパイプライン実行が成功しました"
                    log "  最終更新: $last_update"
                    ;;
                "Failed")
                    log "${RED}✗ 最新のパイプライン実行が失敗しました${NC}"
                    log "  最終更新: $last_update"
                    ;;
                "InProgress")
                    log "${BLUE}i パイプライン実行中です${NC}"
                    ;;
                *)
                    log "${YELLOW}⚠ パイプライン実行状態: $execution_status${NC}"
                    ;;
            esac
        fi
    fi
    
    # Pipeline設定詳細確認
    local stages=$(echo "$pipeline_info" | jq -r '.pipeline.stages[].name')
    log "パイプラインステージ:"
    
    local has_source=false
    local has_build=false
    local has_test=false
    local has_deploy=false
    
    for stage in $stages; do
        log "  - $stage"
        
        case "$stage" in
            *Source*|*source*)
                has_source=true
                ;;
            *Build*|*build*)
                has_build=true
                ;;
            *Test*|*test*)
                has_test=true
                ;;
            *Deploy*|*deploy*)
                has_deploy=true
                ;;
        esac
    done
    
    # 必須ステージの確認
    if [ "$has_source" = true ]; then
        check_success "Sourceステージが設定されています"
    else
        log "${RED}✗ Sourceステージが見つかりません${NC}"
    fi
    
    if [ "$has_build" = true ]; then
        check_success "Buildステージが設定されています"
    else
        log "${YELLOW}⚠ Buildステージが見つかりません${NC}"
    fi
    
    if [ "$has_test" = true ]; then
        check_success "Testステージが設定されています（テストの組み込み確認）"
    else
        log "${YELLOW}⚠ Testステージが見つかりません（推奨: テストステージの追加）${NC}"
    fi
    
    if [ "$has_deploy" = true ]; then
        check_success "Deployステージが設定されています"
    else
        log "${YELLOW}⚠ Deployステージが見つかりません${NC}"
    fi
    
    # GitHub連携確認
    local source_action=$(echo "$pipeline_info" | jq -r '.pipeline.stages[] | select(.name | test("Source|source")) | .actions[0]')
    if [ -n "$source_action" ]; then
        local action_provider=$(echo "$source_action" | jq -r '.actionTypeId.provider')
        local repo_info=$(echo "$source_action" | jq -r '.configuration.FullRepositoryId // .configuration.Repo // "N/A"')
        local branch_info=$(echo "$source_action" | jq -r '.configuration.BranchName // .configuration.Branch // "N/A"')
        
        log "Sourceアクション設定:"
        log "  プロバイダー: $action_provider"
        
        if echo "$action_provider" | grep -qi "github"; then
            check_success "GitHubと連携されています"
            log "  リポジトリ: $repo_info"
            log "  ブランチ: $branch_info"
        elif echo "$action_provider" | grep -qi "codecommit"; then
            log "${BLUE}i CodeCommitを使用しています${NC}"
            log "  リポジトリ: $repo_info"
            log "  ブランチ: $branch_info"
        else
            log "${YELLOW}⚠ ソースプロバイダー: $action_provider${NC}"
        fi
    fi
    
    # CodeBuild プロジェクト検証
    if [ -n "$CODEBUILD_PROJECT_NAME" ]; then
        log "CodeBuild Project: $CODEBUILD_PROJECT_NAME"
        
        local build_project=$(aws codebuild batch-get-projects --names "$CODEBUILD_PROJECT_NAME" 2>/dev/null)
        if [ $? -eq 0 ]; then
            check_success "CodeBuildプロジェクトが存在します"
            
            # ビルド環境確認
            local build_image=$(echo "$build_project" | jq -r '.projects[0].environment.image')
            local compute_type=$(echo "$build_project" | jq -r '.projects[0].environment.computeType')
            local build_timeout=$(echo "$build_project" | jq -r '.projects[0].timeoutInMinutes')
            
            log "  ビルドイメージ: $build_image"
            log "  コンピュートタイプ: $compute_type"
            log "  タイムアウト: ${build_timeout}分"
            
            # 環境変数確認
            local env_vars=$(echo "$build_project" | jq -r '.projects[0].environment.environmentVariables[]? | "\(.name)=\(.value)"')
            if [ -n "$env_vars" ]; then
                log "  環境変数が設定されています"
            fi
            
            # 最新のビルド状態確認
            local recent_builds=$(aws codebuild list-builds-for-project --project-name "$CODEBUILD_PROJECT_NAME" --max-items 5 2>/dev/null)
            if [ $? -eq 0 ]; then
                local build_ids=$(echo "$recent_builds" | jq -r '.ids[0] // empty')
                
                if [ -n "$build_ids" ]; then
                    local build_info=$(aws codebuild batch-get-builds --ids "$build_ids" 2>/dev/null)
                    local build_status=$(echo "$build_info" | jq -r '.builds[0].buildStatus')
                    local build_end_time=$(echo "$build_info" | jq -r '.builds[0].endTime // "実行中"')
                    
                    case "$build_status" in
                        "SUCCEEDED")
                            check_success "最新のビルドが成功しました"
                            log "  完了時刻: $build_end_time"
                            ;;
                        "FAILED")
                            log "${RED}✗ 最新のビルドが失敗しました${NC}"
                            log "  完了時刻: $build_end_time"
                            
                            # エラーの詳細を取得
                            local build_phases=$(echo "$build_info" | jq -r '.builds[0].phases[] | select(.phaseStatus == "FAILED") | .phaseType')
                            if [ -n "$build_phases" ]; then
                                log "${RED}  失敗フェーズ: $build_phases${NC}"
                            fi
                            ;;
                        "IN_PROGRESS")
                            log "${BLUE}i ビルド実行中です${NC}"
                            ;;
                        *)
                            log "${YELLOW}⚠ ビルド状態: $build_status${NC}"
                            ;;
                    esac
                else
                    log "${YELLOW}⚠ ビルド履歴がありません${NC}"
                fi
            fi
            
            # buildspec.yml の確認（プロジェクト設定から）
            local buildspec_location=$(echo "$build_project" | jq -r '.projects[0].source.buildspec // "buildspec.yml"')
            log "  Buildspec: $buildspec_location"
            
        else
            log "${RED}✗ CodeBuildプロジェクトが見つかりません${NC}"
        fi
    else
        log "${YELLOW}CodeBuild Project名が設定されていません${NC}"
        log "${BLUE}i 設定ファイルに CODEBUILD_PROJECT_NAME を追加してください${NC}"
    fi
    
    # デプロイターゲット確認
    local deploy_action=$(echo "$pipeline_info" | jq -r '.pipeline.stages[] | select(.name | test("Deploy|deploy")) | .actions[0]')
    if [ -n "$deploy_action" ]; then
        local deploy_provider=$(echo "$deploy_action" | jq -r '.actionTypeId.provider')
        log "Deployアクション設定:"
        log "  プロバイダー: $deploy_provider"
        
        case "$deploy_provider" in
            "CodeDeploy")
                local app_name=$(echo "$deploy_action" | jq -r '.configuration.ApplicationName')
                local deployment_group=$(echo "$deploy_action" | jq -r '.configuration.DeploymentGroupName')
                check_success "CodeDeployを使用したデプロイが設定されています"
                log "  アプリケーション: $app_name"
                log "  デプロイメントグループ: $deployment_group"
                ;;
            "S3")
                local bucket_name=$(echo "$deploy_action" | jq -r '.configuration.BucketName')
                log "${BLUE}i S3へのデプロイが設定されています${NC}"
                log "  バケット: $bucket_name"
                ;;
            "ECS")
                local cluster_name=$(echo "$deploy_action" | jq -r '.configuration.ClusterName')
                local service_name=$(echo "$deploy_action" | jq -r '.configuration.ServiceName')
                check_success "ECSへのデプロイが設定されています"
                log "  クラスター: $cluster_name"
                log "  サービス: $service_name"
                ;;
            *)
                log "${YELLOW}⚠ デプロイプロバイダー: $deploy_provider${NC}"
                ;;
        esac
    fi
    
    # IAM Role確認（CodePipelineとCodeBuild）
    local pipeline_role=$(echo "$pipeline_info" | jq -r '.pipeline.roleArn')
    if [ -n "$pipeline_role" ]; then
        log "CodePipeline IAM Role: $(basename "$pipeline_role")"
        check_success "CodePipeline用のIAMロールが設定されています"
    fi
    
    if [ -n "$CODEBUILD_PROJECT_NAME" ] && [ "$build_project" != "" ]; then
        local build_role=$(echo "$build_project" | jq -r '.projects[0].serviceRole')
        if [ -n "$build_role" ]; then
            log "CodeBuild IAM Role: $(basename "$build_role")"
            check_success "CodeBuild用のIAMロールが設定されています"
        fi
    fi
}

# LP（ランディングページ）構築検証
verify_lp() {
    log_header "LP（ランディングページ）構築検証"
    
    # LP用S3バケット検証
    if [ -z "$LP_S3_BUCKET_NAME" ]; then
        log "${YELLOW}LP用S3バケット名が設定されていません。スキップします。${NC}"
        log "${BLUE}i 設定ファイルに LP_S3_BUCKET_NAME を追加してください${NC}"
        return 0
    fi
    
    log "LP用S3 Bucket: $LP_S3_BUCKET_NAME"
    
    # バケット存在確認
    if ! aws s3api head-bucket --bucket "$LP_S3_BUCKET_NAME" 2>/dev/null; then
        log "${RED}✗ LP用S3バケットにアクセスできません${NC}"
        return 1
    fi
    check_success "LP用S3バケットが存在します"
    
    # 静的ウェブサイトホスティング設定確認
    local website_config=$(aws s3api get-bucket-website --bucket "$LP_S3_BUCKET_NAME" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local index_document=$(echo "$website_config" | jq -r '.IndexDocument.Suffix')
        local error_document=$(echo "$website_config" | jq -r '.ErrorDocument.Key // "未設定"')
        
        check_success "静的ウェブサイトホスティングが有効です"
        log "  Index Document: $index_document"
        log "  Error Document: $error_document"
        
        if [ "$index_document" = "index.html" ]; then
            check_success "Index Document が index.html に設定されています"
        else
            log "${YELLOW}⚠ Index Document が標準的な index.html ではありません: $index_document${NC}"
        fi
    else
        log "${RED}✗ 静的ウェブサイトホスティングが有効になっていません${NC}"
        log "${YELLOW}  対処: S3コンソールで「プロパティ」→「静的ウェブサイトホスティング」を有効化してください${NC}"
    fi
    
    # LP用S3の暗号化設定確認
    local encryption=$(aws s3api get-bucket-encryption --bucket "$LP_S3_BUCKET_NAME" 2>/dev/null)
    if [ $? -eq 0 ]; then
        check_success "LP用S3バケットが暗号化されています"
        local encryption_type=$(echo "$encryption" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm')
        log "  暗号化方式: $encryption_type"
    else
        log "${RED}✗ LP用S3バケットが暗号化されていません${NC}"
    fi
    
    # バケットポリシー確認（CloudFrontからのアクセス）
    local bucket_policy=$(aws s3api get-bucket-policy --bucket "$LP_S3_BUCKET_NAME" 2>/dev/null)
    if [ $? -eq 0 ]; then
        check_success "LP用バケットポリシーが設定されています"
        
        # CloudFront OACのアクセス許可確認
        if echo "$bucket_policy" | grep -q "cloudfront"; then
            check_success "CloudFront からのアクセスが許可されています"
        else
            log "${YELLOW}⚠ CloudFront からのアクセス設定が見つかりません${NC}"
            log "${YELLOW}  対処: CloudFront OAC (Origin Access Control) を設定してください${NC}"
        fi
    else
        log "${YELLOW}⚠ LP用バケットポリシーが設定されていません${NC}"
        log "${YELLOW}  対処: CloudFront OACを作成し、S3バケットポリシーを更新してください${NC}"
    fi
    
    # LP用CloudFront Distribution確認
    if [ -n "$LP_CLOUDFRONT_DISTRIBUTION_ID" ]; then
        log "LP用CloudFront Distribution: $LP_CLOUDFRONT_DISTRIBUTION_ID"
        
        local lp_distribution_info=$(aws cloudfront get-distribution --id "$LP_CLOUDFRONT_DISTRIBUTION_ID" 2>/dev/null)
        if [ $? -eq 0 ]; then
            check_success "LP用CloudFront Distributionが存在します"
            
            # Origin設定確認（S3オリジン）
            local origin_domain=$(echo "$lp_distribution_info" | jq -r '.Distribution.DistributionConfig.Origins.Items[0].DomainName')
            if echo "$origin_domain" | grep -q "$LP_S3_BUCKET_NAME"; then
                check_success "LP用S3がオリジンとして設定されています"
                log "  Origin: $origin_domain"
            else
                log "${YELLOW}⚠ LP用S3が正しくオリジンに設定されていない可能性があります${NC}"
                log "  Origin: $origin_domain"
            fi
            
            # Default Root Object確認
            local default_root=$(echo "$lp_distribution_info" | jq -r '.Distribution.DistributionConfig.DefaultRootObject')
            if [ "$default_root" = "index.html" ]; then
                check_success "Default Root Object が index.html に設定されています"
            else
                log "${YELLOW}⚠ Default Root Object: $default_root${NC}"
            fi
            
            # Distribution状態確認
            local lp_status=$(echo "$lp_distribution_info" | jq -r '.Distribution.Status')
            if [ "$lp_status" = "Deployed" ]; then
                check_success "LP用CloudFront Distribution が正常にデプロイされています"
            else
                log "${YELLOW}⚠ LP用CloudFront Distribution 状態: $lp_status${NC}"
            fi
            
            # ドメイン名取得
            local lp_domain=$(echo "$lp_distribution_info" | jq -r '.Distribution.DomainName')
            log "  CloudFront Domain: $lp_domain"
            
            # LP用CloudFrontへのアクセステスト
            if curl -s --max-time 10 "https://$lp_domain" >/dev/null 2>&1; then
                check_success "LP用CloudFrontドメインにHTTPS接続できます"
                
                # index.htmlの存在確認
                if curl -s --max-time 10 "https://$lp_domain" | grep -q "<html\|<HTML\|<!DOCTYPE" 2>/dev/null; then
                    check_success "LP用index.htmlが正しく配信されています"
                else
                    log "${YELLOW}⚠ HTMLコンテンツが確認できません${NC}"
                fi
            else
                log "${RED}✗ LP用CloudFrontドメインにHTTPS接続できません${NC}"
            fi
        else
            log "${RED}✗ LP用CloudFront Distributionが見つかりません${NC}"
        fi
    else
        log "${YELLOW}LP用CloudFront Distribution IDが設定されていません${NC}"
        log "${BLUE}i 設定ファイルに LP_CLOUDFRONT_DISTRIBUTION_ID を追加してください${NC}"
    fi
    
    # LP用コンテンツの確認
    log "LP用S3コンテンツ確認:"
    local lp_files=$(aws s3 ls "s3://$LP_S3_BUCKET_NAME/" 2>/dev/null)
    if [ -n "$lp_files" ]; then
        log "${GREEN}✓ LP用S3にファイルが存在します${NC}"
        echo "$lp_files" | head -10 | tee -a "$LOG_FILE"
        
        # index.html の存在確認
        if echo "$lp_files" | grep -q "index.html"; then
            check_success "index.html が存在します"
        else
            log "${RED}✗ index.html が見つかりません${NC}"
            log "${YELLOW}  対処: LP用コンテンツ（index.html等）をS3にアップロードしてください${NC}"
        fi
    else
        log "${YELLOW}⚠ LP用S3にファイルがありません、またはアクセスできません${NC}"
    fi
}

# バージョン情報確認（EC2内で実行される想定）
verify_versions() {
    log_header "バージョン情報確認"
    
    log "${YELLOW}注意: この確認はEC2インスタンス内で実行する必要があります${NC}"
    log "EC2インスタンスで以下のコマンドを実行してください:"
    echo ""
    echo "# Java バージョン確認"
    echo "java -version"
    echo ""
    echo "# Gradle バージョン確認"
    echo "gradle -v"
    echo ""
    echo "# Tomcat バージョン確認"
    echo "/opt/tomcat/bin/version.sh"
    echo ""
    echo "# Git バージョン確認"
    echo "git --version"
    echo ""
    echo "# Maven バージョン確認"
    echo "mvn --version"
}

# メイン実行
main() {
    log_header "AWS リソース検証開始"
    log "実行時刻: $(date)"
    log "ログファイル: $LOG_FILE"
    
    # AWS CLI設定確認
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log "${RED}✗ AWS CLI が設定されていません。aws configure を実行してください。${NC}"
        exit 1
    fi
    
    local aws_identity=$(aws sts get-caller-identity)
    log "AWS Identity: $(echo "$aws_identity" | jq -r '.Arn')"
    log "AWS Region: $(aws configure get region)"
    
    # 各検証の実行
    verify_cloudfront
    verify_alb
    verify_ec2
    verify_security_groups
    verify_rds
    verify_s3
    verify_encryption
    verify_lp
    verify_cicd
    verify_monitoring
    verify_operation
    verify_application_health
    verify_versions
    
    log_header "検証完了"
    log "詳細なログは $LOG_FILE を確認してください。"
}

# スクリプトの直接実行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi