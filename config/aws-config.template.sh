#!/bin/bash
# AWS リソース検証用設定ファイル
# このファイルをコピーして aws-config.sh として使用してください

# ===========================================
# CloudFront 設定
# ===========================================
# CloudFront Distribution ID
CLOUDFRONT_DISTRIBUTION_ID=""
# CloudFront ドメイン名（正常性確認用）
CLOUDFRONT_DOMAIN=""

# ===========================================
# Application Load Balancer 設定
# ===========================================
# ALB の ARN（優先）
ALB_ARN=""
# ALB 名（ARNが不明な場合）
ALB_NAME=""

# ===========================================
# EC2 設定
# ===========================================
# 特定のEC2インスタンスIDを指定する場合（空の場合は実行中の全インスタンスを対象）
EC2_INSTANCE_IDS=""

# ===========================================
# RDS 設定
# ===========================================
# RDS インスタンス ID
RDS_INSTANCE_ID=""
# RDS 接続情報（接続テスト用）
RDS_USERNAME="postgres"
RDS_PASSWORD=""
RDS_DATABASE="movie"

# ===========================================
# S3 設定
# ===========================================
# S3 バケット名
S3_BUCKET_NAME=""

# ===========================================
# その他の設定
# ===========================================
# AWS リージョン（aws configure で設定されていない場合）
AWS_DEFAULT_REGION="ap-northeast-1"

# ===========================================
# 設定例（コメントアウトしてあります）
# ===========================================
# CLOUDFRONT_DISTRIBUTION_ID="E1234567890123"
# CLOUDFRONT_DOMAIN="d1234567890123.cloudfront.net"
# ALB_ARN="arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:loadbalancer/app/my-alb/1234567890123456"
# ALB_NAME="my-application-load-balancer"
# RDS_INSTANCE_ID="rds-tomcat"
# RDS_PASSWORD="your-password-here"
# S3_BUCKET_NAME="my-tomcat-app-bucket"

# ===========================================
# セキュリティに関する注意事項
# ===========================================
# - このファイルには機密情報（パスワード）が含まれる可能性があります
# - .gitignore に aws-config.sh を追加することを強く推奨します
# - 本番環境では環境変数や AWS Secrets Manager の使用を検討してください