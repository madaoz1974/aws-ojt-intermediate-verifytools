#!/bin/bash

# ============================================
# ALB HTTPS セットアップスクリプト
# ============================================
# 自己署名証明書を使用してALBにHTTPSリスナーを追加します
# 
# 使用方法:
#   ./scripts/setup-alb-https.sh
#
# 作成日: 2025-10-09
# ============================================

set -e  # エラーが発生したら即座に終了

# 色の定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ロギング関数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# タイトル表示
echo "============================================"
echo "  ALB HTTPS セットアップスクリプト"
echo "============================================"
echo ""

# 設定ファイルの読み込み
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/aws-config.sh"

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "設定ファイルが見つかりません: $CONFIG_FILE"
    exit 1
fi

log_info "設定ファイルを読み込んでいます..."
source "$CONFIG_FILE"

# 必須パラメータの確認
if [ -z "$ALB_ARN" ]; then
    log_error "ALB_ARN が設定されていません"
    exit 1
fi

log_info "ALB ARN: $ALB_ARN"

# AWS認証情報の確認
log_info "AWS認証情報を確認しています..."
if ! aws sts get-caller-identity &> /dev/null; then
    log_error "AWS認証に失敗しました。aws configure を実行してください。"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
log_success "AWS Account: $ACCOUNT_ID"

# 作業ディレクトリの準備
WORK_DIR="$SCRIPT_DIR/../certs"
log_info "作業ディレクトリを作成しています: $WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ALB情報の取得
log_info "ALB情報を取得しています..."
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

if [ -z "$ALB_DNS" ]; then
    log_error "ALBのDNS名を取得できませんでした"
    exit 1
fi

log_success "ALB DNS: $ALB_DNS"

# ターゲットグループARNの取得
log_info "ターゲットグループ情報を取得しています..."
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
    --load-balancer-arn "$ALB_ARN" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)

if [ -z "$TARGET_GROUP_ARN" ]; then
    log_error "ターゲットグループが見つかりません"
    exit 1
fi

log_success "Target Group ARN: $TARGET_GROUP_ARN"

# 既存のHTTPSリスナーの確認
log_info "既存のHTTPSリスナーを確認しています..."
EXISTING_LISTENER=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[?Port==`443`].ListenerArn' \
    --output text)

if [ -n "$EXISTING_LISTENER" ]; then
    log_warning "HTTPSリスナー（ポート443）は既に存在します"
    echo "既存のリスナーARN: $EXISTING_LISTENER"
    read -p "削除して再作成しますか？ (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "既存のリスナーを削除しています..."
        aws elbv2 delete-listener --listener-arn "$EXISTING_LISTENER"
        log_success "リスナーを削除しました"
    else
        log_info "スクリプトを終了します"
        exit 0
    fi
fi

# ステップ1: OpenSSL設定ファイルの作成
log_info "OpenSSL設定ファイルを作成しています..."
cat > alb-openssl.cnf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
C = JP
ST = Tokyo
L = Tokyo
O = Movie App Development
OU = Infrastructure Team
CN = $ALB_DNS

[v3_req]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = $ALB_DNS
DNS.2 = *.ap-northeast-1.elb.amazonaws.com
EOF

log_success "OpenSSL設定ファイルを作成しました"

# ステップ2: 秘密鍵の生成
log_info "RSA秘密鍵を生成しています（2048bit）..."
if [ -f "alb-private-key.pem" ]; then
    log_warning "既存の秘密鍵をバックアップしています..."
    mv alb-private-key.pem "alb-private-key.pem.bak.$(date +%Y%m%d%H%M%S)"
fi

openssl genrsa -out alb-private-key.pem 2048 2>/dev/null
chmod 400 alb-private-key.pem

# 秘密鍵の検証
if openssl rsa -in alb-private-key.pem -check -noout &>/dev/null; then
    log_success "秘密鍵を生成しました"
else
    log_error "秘密鍵の生成に失敗しました"
    exit 1
fi

# ステップ3: 自己署名証明書の生成
log_info "自己署名証明書を生成しています（有効期限: 365日）..."
if [ -f "alb-certificate.pem" ]; then
    log_warning "既存の証明書をバックアップしています..."
    mv alb-certificate.pem "alb-certificate.pem.bak.$(date +%Y%m%d%H%M%S)"
fi

openssl req -new -x509 -days 365 \
    -key alb-private-key.pem \
    -out alb-certificate.pem \
    -config alb-openssl.cnf 2>/dev/null

log_success "証明書を生成しました"

# 証明書の内容確認
log_info "証明書の内容を確認しています..."
CERT_SUBJECT=$(openssl x509 -in alb-certificate.pem -noout -subject | sed 's/subject=//')
CERT_EXPIRY=$(openssl x509 -in alb-certificate.pem -noout -enddate | sed 's/notAfter=//')

echo "  Subject: $CERT_SUBJECT"
echo "  有効期限: $CERT_EXPIRY"

# 証明書と秘密鍵の整合性確認
log_info "証明書と秘密鍵の整合性を確認しています..."
CERT_MODULUS=$(openssl x509 -noout -modulus -in alb-certificate.pem | openssl md5)
KEY_MODULUS=$(openssl rsa -noout -modulus -in alb-private-key.pem | openssl md5)

if [ "$CERT_MODULUS" = "$KEY_MODULUS" ]; then
    log_success "証明書と秘密鍵が一致しています"
else
    log_error "証明書と秘密鍵が一致しません"
    exit 1
fi

# ステップ4: IAMに証明書をアップロード
CERT_NAME="vs-prod-alb-self-signed-cert-$(date +%Y%m%d-%H%M%S)"
log_info "証明書をIAMにアップロードしています..."
log_info "証明書名: $CERT_NAME"

UPLOAD_RESULT=$(aws iam upload-server-certificate \
    --server-certificate-name "$CERT_NAME" \
    --certificate-body file://alb-certificate.pem \
    --private-key file://alb-private-key.pem \
    --path /cloudfront/ \
    2>&1)

if [ $? -eq 0 ]; then
    log_success "証明書をIAMにアップロードしました"
else
    log_error "証明書のアップロードに失敗しました"
    echo "$UPLOAD_RESULT"
    exit 1
fi

# 証明書ARNの取得（少し待ってから）
log_info "証明書ARNを取得しています..."
sleep 3

CERT_ARN=$(aws iam list-server-certificates \
    --query "ServerCertificateMetadataList[?ServerCertificateName=='$CERT_NAME'].Arn" \
    --output text)

if [ -z "$CERT_ARN" ]; then
    log_error "証明書ARNを取得できませんでした"
    exit 1
fi

log_success "証明書ARN: $CERT_ARN"

# ステップ5: Security Groupの確認と設定
log_info "Security Groupを確認しています..."
ALB_SG=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].SecurityGroups[0]' \
    --output text)

log_info "ALB Security Group: $ALB_SG"

# ポート443の確認
SG_443_RULE=$(aws ec2 describe-security-groups \
    --group-ids "$ALB_SG" \
    --query 'SecurityGroups[0].IpPermissions[?ToPort==`443`]' \
    --output text)

if [ -z "$SG_443_RULE" ]; then
    log_warning "ポート443が開放されていません。開放しています..."
    aws ec2 authorize-security-group-ingress \
        --group-id "$ALB_SG" \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0
    log_success "ポート443を開放しました"
else
    log_success "ポート443は既に開放されています"
fi

# ステップ6: HTTPSリスナーの作成
log_info "HTTPSリスナー（ポート443）を作成しています..."
LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTPS \
    --port 443 \
    --certificates CertificateArn="$CERT_ARN" \
    --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
    --default-actions Type=forward,TargetGroupArn="$TARGET_GROUP_ARN" \
    --query 'Listeners[0].ListenerArn' \
    --output text)

if [ -n "$LISTENER_ARN" ]; then
    log_success "HTTPSリスナーを作成しました"
    log_success "Listener ARN: $LISTENER_ARN"
else
    log_error "HTTPSリスナーの作成に失敗しました"
    exit 1
fi

# ステップ7: 動作確認
log_info "ALBへのHTTPS接続をテストしています..."
sleep 5

HTTP_STATUS=$(curl -Isk --max-time 10 "https://$ALB_DNS" | head -1)

if [ -n "$HTTP_STATUS" ]; then
    log_success "HTTPS接続テスト成功: $HTTP_STATUS"
else
    log_warning "HTTPS接続テストに失敗しました（タイムアウトの可能性）"
    log_warning "ターゲットグループのヘルスチェックを確認してください"
fi

# 完了メッセージ
echo ""
echo "============================================"
log_success "セットアップが完了しました！"
echo "============================================"
echo ""
echo "📋 セットアップサマリー:"
echo "  - 証明書名: $CERT_NAME"
echo "  - 証明書ARN: $CERT_ARN"
echo "  - リスナーARN: $LISTENER_ARN"
echo "  - ALB DNS: $ALB_DNS"
echo ""
echo "🔍 次のステップ:"
echo "  1. CloudFrontの設定を変更してください"
echo "     - デフォルトビヘイビアのオリジンを 'alb-origin' に変更"
echo ""
echo "  2. CloudFrontのデプロイ完了を待ってください（15-20分）"
echo "     aws cloudfront get-distribution --id $CLOUDFRONT_DISTRIBUTION_ID --query 'Distribution.Status'"
echo ""
echo "  3. 動作確認を実行してください"
echo "     curl -I https://$CLOUDFRONT_DOMAIN"
echo ""
echo "  4. 検証スクリプトを実行してください"
echo "     ./scripts/verify-aws-resources.sh"
echo ""
log_warning "証明書ファイルは $WORK_DIR に保存されています"
log_warning "セキュリティのため、不要になったら削除してください"
echo ""
