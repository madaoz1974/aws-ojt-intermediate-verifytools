#!/bin/bash

# Elastic IP 使用状況分析と最適化提案スクリプト

echo "=========================================="
echo "Elastic IP 使用状況分析"
echo "=========================================="

# 1. 現在のElastic IP使用状況
echo "1. 現在のElastic IP使用状況:"
aws ec2 describe-addresses --query 'Addresses[*].{AllocationId:AllocationId,PublicIp:PublicIp,InstanceId:InstanceId,NetworkInterfaceId:NetworkInterfaceId,Domain:Domain}' --output table

echo -e "\n2. サービス制限確認:"
current_limit=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 --query 'Quota.Value' --output text 2>/dev/null || echo "5")
echo "現在の制限: ${current_limit}個"

echo -e "\n3. 未使用のElastic IP特定:"
echo "=== EC2インスタンスに関連付けられていないElastic IP ==="
aws ec2 describe-addresses --query 'Addresses[?InstanceId==`null` || InstanceId==``]' --output table

echo -e "\n4. 停止中のEC2インスタンス確認:"
aws ec2 describe-instances --filters "Name=instance-state-name,Values=stopped" --query 'Reservations[*].Instances[*].{InstanceId:InstanceId,State:State.Name,PublicIp:PublicIpAddress}' --output table

echo -e "\n5. NAT Gateway使用状況:"
aws ec2 describe-nat-gateways --query 'NatGateways[*].{NatGatewayId:NatGatewayId,State:State,PublicIp:NatGatewayAddresses[0].PublicIp,SubnetId:SubnetId}' --output table

echo -e "\n=========================================="
echo "推奨解決策"
echo "=========================================="

echo "【方法1】不要なElastic IPの解放"
echo "- 停止中のインスタンスからElastic IPを解放"
echo "- 未使用のElastic IPを削除"

echo -e "\n【方法2】プライベートサブネット構成への変更"
echo "- 4つのEC2をプライベートサブネットに配置"
echo "- NAT Gateway経由でインターネットアクセス"
echo "- 必要なElastic IP: 1個のみ（NAT Gateway用）"

echo -e "\n【方法3】サービス制限引き上げ"
echo "- AWS Service Quotasで制限を10個に引き上げ申請"
echo "- 申請理由: マルチEC2環境での開発・テスト用途"

echo -e "\n=========================================="
echo "分析完了"
echo "=========================================="