#!/bin/bash

# CloudFront ⇔ EC2 疎通テストスクリプト

# 設定読み込み
source /workspaces/aws-ojt-intermediate-verifytools/config/aws-config.sh

# カラー設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "=========================================="
echo "CloudFront ⇔ EC2 疎通テスト"
echo "=========================================="
echo "実行時刻: $(date)"
echo "CloudFront Domain: $CLOUDFRONT_DOMAIN"
echo "ALB ARN: $ALB_ARN"

# 1. ALB直接アクセステスト
echo -e "\n${BLUE}1. ALB エンドポイント確認${NC}"
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)
echo "ALB DNS: $ALB_DNS"

echo -e "\n${BLUE}2. ALB直接アクセステスト (ポート80)${NC}"
if curl -s --max-time 10 "http://$ALB_DNS/" > /dev/null; then
    echo -e "${GREEN}✓ ALB HTTP接続成功${NC}"
    alb_content=$(curl -s "http://$ALB_DNS/" | head -10)
    echo "レスポンス例:"
    echo "$alb_content"
else
    echo -e "${RED}✗ ALB HTTP接続失敗${NC}"
fi

# 2. CloudFront経由テスト
echo -e "\n${BLUE}3. CloudFront 経由テスト${NC}"

echo -e "\n${YELLOW}3.1 Tomcat ウェルカムページテスト${NC}"
if curl -s --max-time 15 "https://$CLOUDFRONT_DOMAIN/" > /dev/null; then
    echo -e "${GREEN}✓ CloudFront HTTPS接続成功${NC}"
    
    # HTMLコンテンツの分析
    content=$(curl -s "https://$CLOUDFRONT_DOMAIN/")
    
    if echo "$content" | grep -qi "tomcat\|apache"; then
        echo -e "${GREEN}✓ Tomcat関連コンテンツを検出${NC}"
    elif echo "$content" | grep -qi "welcome\|index"; then
        echo -e "${YELLOW}⚠ ウェルカムページらしきコンテンツを検出${NC}"
    else
        echo -e "${RED}✗ Tomcatウェルカムページが見つかりません${NC}"
    fi
    
    echo -e "\nレスポンス内容（最初の20行）:"
    echo "$content" | head -20
    
else
    echo -e "${RED}✗ CloudFront HTTPS接続失敗${NC}"
fi

echo -e "\n${YELLOW}3.2 Spring Boot エラーページテスト${NC}"

# Spring Bootでよく使われるパス
test_paths=("/app" "/api" "/actuator" "/contents/movie" "/movie" "/health" "/info")

for path in "${test_paths[@]}"; do
    echo "Testing: https://$CLOUDFRONT_DOMAIN$path"
    
    # HTTP ステータスコードの取得
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://$CLOUDFRONT_DOMAIN$path")
    
    echo "  HTTP Status: $http_code"
    
    # レスポンス内容の確認
    if [ "$http_code" != "000" ]; then
        content=$(curl -s "https://$CLOUDFRONT_DOMAIN$path" | head -5)
        
        # Spring Boot エラーページの特徴を確認
        if echo "$content" | grep -qi "whitelabel\|spring\|error"; then
            echo -e "  ${GREEN}✓ Spring Boot エラーページを検出${NC}"
        elif echo "$content" | grep -qi "404\|not found"; then
            echo -e "  ${YELLOW}⚠ 標準的な404エラーページ${NC}"
        elif echo "$content" | grep -qi "tomcat"; then
            echo -e "  ${BLUE}i Tomcat関連のページ${NC}"
        else
            echo -e "  ${RED}- 内容不明${NC}"
        fi
        
        # 簡単な内容表示
        if [ -n "$content" ]; then
            echo "  内容例: $(echo "$content" | tr '\n' ' ' | cut -c1-100)..."
        fi
    else
        echo -e "  ${RED}✗ 接続失敗${NC}"
    fi
    echo ""
done

# 4. 詳細なヘッダー情報の確認
echo -e "\n${BLUE}4. CloudFront レスポンスヘッダー確認${NC}"
curl -I "https://$CLOUDFRONT_DOMAIN/" 2>/dev/null | grep -E "(Server|X-|CloudFront|Cache|Via)"

# 5. ALBとCloudFrontの応答時間比較
echo -e "\n${BLUE}5. 応答時間比較${NC}"
echo "ALB直接アクセス:"
curl -o /dev/null -s -w "  応答時間: %{time_total}秒\n" "http://$ALB_DNS/"

echo "CloudFront経由:"
curl -o /dev/null -s -w "  応答時間: %{time_total}秒\n" "https://$CLOUDFRONT_DOMAIN/"

# 6. Tomcat固有のエンドポイントテスト
echo -e "\n${BLUE}6. Tomcat固有のエンドポイントテスト${NC}"
tomcat_paths=("/manager" "/docs" "/examples" "/host-manager")

for path in "${tomcat_paths[@]}"; do
    echo "Testing Tomcat path: https://$CLOUDFRONT_DOMAIN$path"
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://$CLOUDFRONT_DOMAIN$path")
    echo "  HTTP Status: $http_code"
    
    if [ "$http_code" = "200" ]; then
        echo -e "  ${GREEN}✓ アクセス可能${NC}"
    elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        echo -e "  ${YELLOW}⚠ 認証が必要または禁止されています（Tomcatが動作している証拠）${NC}"
    elif [ "$http_code" = "404" ]; then
        echo -e "  ${BLUE}i 404エラー（設定によっては正常）${NC}"
    else
        echo -e "  ${RED}- その他のステータス${NC}"
    fi
done

echo -e "\n=========================================="
echo "疎通テスト完了"
echo "=========================================="