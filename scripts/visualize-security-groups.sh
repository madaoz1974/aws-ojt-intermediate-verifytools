#!/bin/bash

# Security Group Dependency Visualization Script
# EC2インスタンスを起点としてセキュリティグループの依存関係を可視化

# カラー出力設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# ログディレクトリとファイル
LOG_DIR="/workspaces/aws-ojt-intermediate-verifytools/log"
mkdir -p "$LOG_DIR"
OUTPUT_FILE="$LOG_DIR/security_group_dependencies_$(date +%Y%m%d_%H%M%S).txt"

# ヘルパー関数
log() {
    echo -e "$1" | tee -a "$OUTPUT_FILE"
}

log_header() {
    echo "" | tee -a "$OUTPUT_FILE"
    echo "========================================" | tee -a "$OUTPUT_FILE"
    echo "$1" | tee -a "$OUTPUT_FILE"
    echo "========================================" | tee -a "$OUTPUT_FILE"
}

# セキュリティグループの詳細情報を取得
get_sg_info() {
    local sg_id="$1"
    aws ec2 describe-security-groups --group-ids "$sg_id" 2>/dev/null
}

# セキュリティグループ名を取得
get_sg_name() {
    local sg_id="$1"
    local sg_info=$(get_sg_info "$sg_id")
    echo "$sg_info" | jq -r '.SecurityGroups[0].GroupName // "Unknown"'
}

# セキュリティグループの説明を取得
get_sg_description() {
    local sg_id="$1"
    local sg_info=$(get_sg_info "$sg_id")
    echo "$sg_info" | jq -r '.SecurityGroups[0].Description // "No description"'
}

# インバウンドルールの解析
analyze_inbound_rules() {
    local sg_id="$1"
    local indent="$2"
    local sg_info=$(get_sg_info "$sg_id")
    
    if [ -z "$sg_info" ]; then
        return
    fi
    
    local rules=$(echo "$sg_info" | jq -r '.SecurityGroups[0].IpPermissions[]')
    
    if [ -z "$rules" ]; then
        log "${indent}  インバウンドルール: なし"
        return
    fi
    
    echo "$sg_info" | jq -r '.SecurityGroups[0].IpPermissions[] | 
        {
            protocol: (if .IpProtocol == "-1" then "All" else .IpProtocol end),
            from_port: .FromPort,
            to_port: .ToPort,
            cidr: .IpRanges[].CidrIp,
            sg_ref: .UserIdGroupPairs[].GroupId,
            sg_desc: .UserIdGroupPairs[].Description
        } | 
        select(. != null)' 2>/dev/null | while read -r line; do
        
        local protocol=$(echo "$line" | jq -r '.protocol // "Unknown"')
        local from_port=$(echo "$line" | jq -r '.from_port // "N/A"')
        local to_port=$(echo "$line" | jq -r '.to_port // "N/A"')
        local cidr=$(echo "$line" | jq -r '.cidr // empty')
        local sg_ref=$(echo "$line" | jq -r '.sg_ref // empty')
        local sg_desc=$(echo "$line" | jq -r '.sg_desc // empty')
        
        if [ -n "$cidr" ]; then
            if [ "$cidr" = "0.0.0.0/0" ]; then
                log "${indent}  ${RED}▶ ${protocol}:${from_port}-${to_port} ← 0.0.0.0/0 (全世界公開)${NC}"
            else
                log "${indent}  ${YELLOW}▶ ${protocol}:${from_port}-${to_port} ← ${cidr}${NC}"
            fi
        fi
        
        if [ -n "$sg_ref" ]; then
            local ref_name=$(get_sg_name "$sg_ref")
            if [ -n "$sg_desc" ]; then
                log "${indent}  ${GREEN}▶ ${protocol}:${from_port}-${to_port} ← ${sg_ref} (${ref_name}) - ${sg_desc}${NC}"
            else
                log "${indent}  ${GREEN}▶ ${protocol}:${from_port}-${to_port} ← ${sg_ref} (${ref_name})${NC}"
            fi
        fi
    done
    
    # CIDR形式のルール
    echo "$sg_info" | jq -r '.SecurityGroups[0].IpPermissions[] | 
        select(.IpRanges | length > 0) | 
        {
            protocol: (if .IpProtocol == "-1" then "All" else .IpProtocol end),
            from_port: .FromPort,
            to_port: .ToPort
        } as $base |
        .IpRanges[] | 
        $base + {cidr: .CidrIp, desc: .Description}' 2>/dev/null | jq -s '.' | jq -r '.[] | 
        "\(.protocol):\(.from_port // "N/A")-\(.to_port // "N/A") ← \(.cidr) \(if .desc then "(\(.desc))" else "" end)"' | while read -r rule; do
        
        if echo "$rule" | grep -q "0.0.0.0/0"; then
            log "${indent}  ${RED}▶ $rule${NC}"
        else
            log "${indent}  ${YELLOW}▶ $rule${NC}"
        fi
    done
    
    # SG参照のルール
    echo "$sg_info" | jq -r '.SecurityGroups[0].IpPermissions[] | 
        select(.UserIdGroupPairs | length > 0) | 
        {
            protocol: (if .IpProtocol == "-1" then "All" else .IpProtocol end),
            from_port: .FromPort,
            to_port: .ToPort
        } as $base |
        .UserIdGroupPairs[] | 
        $base + {sg_ref: .GroupId, sg_desc: .Description}' 2>/dev/null | jq -s '.' | jq -r '.[] | 
        "\(.protocol):\(.from_port // "N/A")-\(.to_port // "N/A") ← \(.sg_ref) \(if .sg_desc then "(\(.sg_desc))" else "" end)"' | while read -r rule; do
        
        local sg_ref=$(echo "$rule" | grep -oP 'sg-[a-f0-9]+')
        local ref_name=$(get_sg_name "$sg_ref")
        local formatted_rule=$(echo "$rule" | sed "s/$sg_ref/$sg_ref ($ref_name)/")
        log "${indent}  ${GREEN}▶ $formatted_rule${NC}"
    done
}

# アウトバウンドルールの解析
analyze_outbound_rules() {
    local sg_id="$1"
    local indent="$2"
    local sg_info=$(get_sg_info "$sg_id")
    
    if [ -z "$sg_info" ]; then
        return
    fi
    
    local rules=$(echo "$sg_info" | jq -r '.SecurityGroups[0].IpPermissionsEgress[]')
    
    if [ -z "$rules" ]; then
        log "${indent}  アウトバウンドルール: なし"
        return
    fi
    
    # CIDR形式のルール
    echo "$sg_info" | jq -r '.SecurityGroups[0].IpPermissionsEgress[] | 
        select(.IpRanges | length > 0) | 
        {
            protocol: (if .IpProtocol == "-1" then "All" else .IpProtocol end),
            from_port: .FromPort,
            to_port: .ToPort
        } as $base |
        .IpRanges[] | 
        $base + {cidr: .CidrIp, desc: .Description}' 2>/dev/null | jq -s '.' | jq -r '.[] | 
        "\(.protocol):\(.from_port // "N/A")-\(.to_port // "N/A") → \(.cidr) \(if .desc then "(\(.desc))" else "" end)"' | while read -r rule; do
        
        if echo "$rule" | grep -q "0.0.0.0/0"; then
            log "${indent}  ${CYAN}▶ $rule${NC}"
        else
            log "${indent}  ${YELLOW}▶ $rule${NC}"
        fi
    done
    
    # SG参照のルール
    echo "$sg_info" | jq -r '.SecurityGroups[0].IpPermissionsEgress[] | 
        select(.UserIdGroupPairs | length > 0) | 
        {
            protocol: (if .IpProtocol == "-1" then "All" else .IpProtocol end),
            from_port: .FromPort,
            to_port: .ToPort
        } as $base |
        .UserIdGroupPairs[] | 
        $base + {sg_ref: .GroupId, sg_desc: .Description}' 2>/dev/null | jq -s '.' | jq -r '.[] | 
        "\(.protocol):\(.from_port // "N/A")-\(.to_port // "N/A") → \(.sg_ref) \(if .sg_desc then "(\(.sg_desc))" else "" end)"' | while read -r rule; do
        
        local sg_ref=$(echo "$rule" | grep -oP 'sg-[a-f0-9]+')
        local ref_name=$(get_sg_name "$sg_ref")
        local formatted_rule=$(echo "$rule" | sed "s/$sg_ref/$sg_ref ($ref_name)/")
        log "${indent}  ${GREEN}▶ $formatted_rule${NC}"
    done
}

# EC2インスタンスのセキュリティグループを可視化
visualize_ec2_security_groups() {
    log_header "EC2インスタンスのセキュリティグループ依存関係"
    
    # 全てのEC2インスタンスを取得
    local instances=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],SecurityGroups[*].GroupId]' --output json)
    
    local instance_count=$(echo "$instances" | jq -r 'length')
    log "実行中のEC2インスタンス数: $instance_count"
    echo ""
    
    echo "$instances" | jq -c '.[][]' | while read -r instance; do
        local instance_id=$(echo "$instance" | jq -r '.[0]')
        local instance_name=$(echo "$instance" | jq -r '.[1] // "名前なし"')
        local security_groups=$(echo "$instance" | jq -r '.[2][]')
        
        log "${BLUE}┌─────────────────────────────────────────────────────────────────${NC}"
        log "${BLUE}│ EC2インスタンス: ${instance_id} (${instance_name})${NC}"
        log "${BLUE}└─────────────────────────────────────────────────────────────────${NC}"
        echo ""
        
        for sg_id in $security_groups; do
            local sg_name=$(get_sg_name "$sg_id")
            local sg_desc=$(get_sg_description "$sg_id")
            
            log "  ${MAGENTA}■ Security Group: ${sg_id}${NC}"
            log "    名前: ${sg_name}"
            log "    説明: ${sg_desc}"
            echo ""
            
            log "    ${CYAN}【インバウンドルール】${NC}"
            analyze_inbound_rules "$sg_id" "    "
            echo ""
            
            log "    ${CYAN}【アウトバウンドルール】${NC}"
            analyze_outbound_rules "$sg_id" "    "
            echo ""
            echo ""
        done
    done
}

# ALBのセキュリティグループを可視化
visualize_alb_security_groups() {
    log_header "ALBのセキュリティグループ依存関係"
    
    # 全てのALBを取得
    local albs=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[*].[LoadBalancerArn,LoadBalancerName,SecurityGroups]' --output json)
    
    local alb_count=$(echo "$albs" | jq -r 'length')
    log "ALB数: $alb_count"
    echo ""
    
    if [ "$alb_count" -eq 0 ]; then
        log "ALBが見つかりませんでした"
        return
    fi
    
    echo "$albs" | jq -c '.[]' | while read -r alb; do
        local alb_arn=$(echo "$alb" | jq -r '.[0]')
        local alb_name=$(echo "$alb" | jq -r '.[1]')
        local security_groups=$(echo "$alb" | jq -r '.[2][]')
        
        log "${BLUE}┌─────────────────────────────────────────────────────────────────${NC}"
        log "${BLUE}│ ALB: ${alb_name}${NC}"
        log "${BLUE}└─────────────────────────────────────────────────────────────────${NC}"
        echo ""
        
        for sg_id in $security_groups; do
            local sg_name=$(get_sg_name "$sg_id")
            local sg_desc=$(get_sg_description "$sg_id")
            
            log "  ${MAGENTA}■ Security Group: ${sg_id}${NC}"
            log "    名前: ${sg_name}"
            log "    説明: ${sg_desc}"
            echo ""
            
            log "    ${CYAN}【インバウンドルール】${NC}"
            analyze_inbound_rules "$sg_id" "    "
            echo ""
            
            log "    ${CYAN}【アウトバウンドルール】${NC}"
            analyze_outbound_rules "$sg_id" "    "
            echo ""
            echo ""
        done
    done
}

# RDSのセキュリティグループを可視化
visualize_rds_security_groups() {
    log_header "RDSのセキュリティグループ依存関係"
    
    # 全てのRDSインスタンスを取得
    local rds_instances=$(aws rds describe-db-instances --query 'DBInstances[*].[DBInstanceIdentifier,VpcSecurityGroups[*].VpcSecurityGroupId]' --output json)
    
    local rds_count=$(echo "$rds_instances" | jq -r 'length')
    log "RDSインスタンス数: $rds_count"
    echo ""
    
    if [ "$rds_count" -eq 0 ]; then
        log "RDSインスタンスが見つかりませんでした"
        return
    fi
    
    echo "$rds_instances" | jq -c '.[]' | while read -r rds; do
        local rds_id=$(echo "$rds" | jq -r '.[0]')
        local security_groups=$(echo "$rds" | jq -r '.[1][]')
        
        log "${BLUE}┌─────────────────────────────────────────────────────────────────${NC}"
        log "${BLUE}│ RDS: ${rds_id}${NC}"
        log "${BLUE}└─────────────────────────────────────────────────────────────────${NC}"
        echo ""
        
        for sg_id in $security_groups; do
            local sg_name=$(get_sg_name "$sg_id")
            local sg_desc=$(get_sg_description "$sg_id")
            
            log "  ${MAGENTA}■ Security Group: ${sg_id}${NC}"
            log "    名前: ${sg_name}"
            log "    説明: ${sg_desc}"
            echo ""
            
            log "    ${CYAN}【インバウンドルール】${NC}"
            analyze_inbound_rules "$sg_id" "    "
            echo ""
            
            log "    ${CYAN}【アウトバウンドルール】${NC}"
            analyze_outbound_rules "$sg_id" "    "
            echo ""
            echo ""
        done
    done
}

# セキュリティグループの依存関係マップを作成
create_dependency_map() {
    log_header "セキュリティグループ依存関係マップ"
    
    log "【凡例】"
    log "${RED}  ● 0.0.0.0/0 (全世界公開) - セキュリティリスク高${NC}"
    log "${GREEN}  ● Security Group参照 - 推奨設定${NC}"
    log "${YELLOW}  ● 特定CIDR範囲${NC}"
    log "${CYAN}  ● アウトバウンド通信${NC}"
    echo ""
    
    log "【依存関係フロー】"
    log ""
    log "Internet (0.0.0.0/0)"
    log "    ↓"
    log "CloudFront"
    log "    ↓"
    log "ALB (Security Group)"
    log "    ↓ (SG参照)"
    log "EC2 (Security Group)"
    log "    ↓ (SG参照)"
    log "RDS (Security Group)"
    echo ""
}

# セキュリティリスク分析
analyze_security_risks() {
    log_header "セキュリティリスク分析"
    
    # 0.0.0.0/0で公開されているSGを検索
    local all_sgs=$(aws ec2 describe-security-groups --query 'SecurityGroups[*].GroupId' --output text)
    
    log "${RED}【警告】0.0.0.0/0 に公開されているセキュリティグループ:${NC}"
    echo ""
    
    local risk_found=false
    
    for sg_id in $all_sgs; do
        local sg_info=$(get_sg_info "$sg_id")
        local sg_name=$(echo "$sg_info" | jq -r '.SecurityGroups[0].GroupName')
        
        # 0.0.0.0/0の確認
        local has_public=$(echo "$sg_info" | jq -r '.SecurityGroups[0].IpPermissions[] | select(.IpRanges[].CidrIp == "0.0.0.0/0") | .IpProtocol' | head -1)
        
        if [ -n "$has_public" ]; then
            risk_found=true
            log "${RED}  ⚠ ${sg_id} (${sg_name})${NC}"
            
            # 公開されているポートを列挙
            echo "$sg_info" | jq -r '.SecurityGroups[0].IpPermissions[] | 
                select(.IpRanges[].CidrIp == "0.0.0.0/0") | 
                {
                    protocol: (if .IpProtocol == "-1" then "All" else .IpProtocol end),
                    from_port: .FromPort,
                    to_port: .ToPort
                } | 
                "      - \(.protocol):\(.from_port // "All")-\(.to_port // "All")"' | sort -u | while read -r port; do
                log "${RED}$port${NC}"
            done
            echo ""
        fi
    done
    
    if [ "$risk_found" = false ]; then
        log "${GREEN}  ✓ 0.0.0.0/0 に公開されているセキュリティグループはありません${NC}"
    fi
    
    echo ""
    log "${GREEN}【推奨】Security Group参照を使用しているセキュリティグループ:${NC}"
    echo ""
    
    local good_practice_found=false
    
    for sg_id in $all_sgs; do
        local sg_info=$(get_sg_info "$sg_id")
        local sg_name=$(echo "$sg_info" | jq -r '.SecurityGroups[0].GroupName')
        
        # SG参照の確認
        local has_sg_ref=$(echo "$sg_info" | jq -r '.SecurityGroups[0].IpPermissions[] | select(.UserIdGroupPairs | length > 0) | .UserIdGroupPairs[0].GroupId' | head -1)
        
        if [ -n "$has_sg_ref" ]; then
            good_practice_found=true
            log "${GREEN}  ✓ ${sg_id} (${sg_name})${NC}"
            
            # 参照しているSGを列挙
            echo "$sg_info" | jq -r '.SecurityGroups[0].IpPermissions[] | 
                select(.UserIdGroupPairs | length > 0) | 
                .UserIdGroupPairs[].GroupId' | sort -u | while read -r ref_sg; do
                local ref_name=$(get_sg_name "$ref_sg")
                log "${GREEN}      → ${ref_sg} (${ref_name})${NC}"
            done
            echo ""
        fi
    done
    
    if [ "$good_practice_found" = false ]; then
        log "${YELLOW}  ⚠ Security Group参照を使用しているセキュリティグループが見つかりません${NC}"
    fi
}

# メイン実行
main() {
    log_header "セキュリティグループ依存関係可視化"
    log "実行時刻: $(date)"
    log "出力ファイル: $OUTPUT_FILE"
    echo ""
    
    # AWS CLI設定確認
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log "${RED}✗ AWS CLI が設定されていません。aws configure を実行してください。${NC}"
        exit 1
    fi
    
    local aws_identity=$(aws sts get-caller-identity)
    log "AWS Identity: $(echo "$aws_identity" | jq -r '.Arn')"
    log "AWS Region: $(aws configure get region)"
    echo ""
    
    # 各可視化の実行
    create_dependency_map
    visualize_ec2_security_groups
    visualize_alb_security_groups
    visualize_rds_security_groups
    analyze_security_risks
    
    log_header "可視化完了"
    log "詳細な情報は $OUTPUT_FILE を確認してください。"
}

# スクリプトの直接実行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
