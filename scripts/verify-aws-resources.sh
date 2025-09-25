#!/bin/bash

# AWS Resource Verification Script
# 成果物確認ポイントに基づくAWSリソースの検証

set -e

# カラー出力設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ログファイル
LOG_FILE="/workspace/verification_$(date +%Y%m%d_%H%M%S).log"

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
if [ -f "/workspace/config/aws-config.sh" ]; then
    source /workspace/config/aws-config.sh
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
    
    # /contents/ パスルーティング確認
    local default_root_object=$(echo "$distribution_info" | jq -r '.Distribution.DistributionConfig.DefaultRootObject')
    local origins=$(echo "$distribution_info" | jq -r '.Distribution.DistributionConfig.Origins.Items[].DomainName')
    
    log "Default Root Object: $default_root_object"
    log "Origins: $origins"
    
    # Cache Behaviors確認
    local behaviors=$(echo "$distribution_info" | jq -r '.Distribution.DistributionConfig.CacheBehaviors.Items[]?.PathPattern // empty')
    if echo "$behaviors" | grep -q "/contents/*"; then
        log "${GREEN}✓ /contents/ パスルーティングが設定されています${NC}"
    else
        log "${YELLOW}⚠ /contents/ パスルーティングが明示的に設定されていない可能性があります${NC}"
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
            check_success "CloudFront (OAC) のアクセスが設定されています"
        else
            log "${YELLOW}⚠ CloudFront (OAC) のアクセス設定が明確ではありません${NC}"
        fi
        
        if echo "$bucket_policy" | grep -q "arn:aws:iam::.*:role"; then
            check_success "IAM Role のアクセスが設定されています"
        else
            log "${YELLOW}⚠ IAM Role のアクセス設定が明確ではありません${NC}"
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
    verify_application_health
    verify_versions
    
    log_header "検証完了"
    log "詳細なログは $LOG_FILE を確認してください。"
}

# スクリプトの直接実行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi