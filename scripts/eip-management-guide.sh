#!/bin/bash

# Elastic IP解放と再割り当てスクリプト
# 注意: 実行前に必ず内容を確認してください

echo "=========================================="
echo "Elastic IP 解放・再割り当て手順"
echo "=========================================="

echo "【現在の状況】"
echo "停止中のインスタンス:"
aws ec2 describe-instances --filters "Name=instance-state-name,Values=stopped" --query 'Reservations[*].Instances[*].{InstanceId:InstanceId,PublicIp:PublicIpAddress}' --output table

echo -e "\n【手動実行が必要なコマンド】"
echo "停止中インスタンスからElastic IPを解放:"

# 停止中のインスタンスのElastic IP関連付けを取得
stopped_instances=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=stopped" --query 'Reservations[*].Instances[*].InstanceId' --output text)

for instance in $stopped_instances; do
    allocation_id=$(aws ec2 describe-addresses --filters "Name=instance-id,Values=$instance" --query 'Addresses[0].AllocationId' --output text 2>/dev/null)
    if [ "$allocation_id" != "None" ] && [ -n "$allocation_id" ]; then
        echo "aws ec2 disassociate-address --association-id \$(aws ec2 describe-addresses --filters \"Name=instance-id,Values=$instance\" --query 'Addresses[0].AssociationId' --output text)"
        echo "# インスタンス $instance からElastic IPを解放"
    fi
done

echo -e "\n【プライベートサブネット配置の提案】"
echo "新しい4つのEC2インスタンスはプライベートサブネットに配置することを推奨:"
echo "1. EC2インスタンスをプライベートサブネットで起動"
echo "2. 既存のNAT Gateway経由でインターネットアクセス"
echo "3. Elastic IP不要（NAT Gatewayが既に設定済み）"

echo -e "\n【確認コマンド】"
echo "プライベートサブネット一覧:"
echo "aws ec2 describe-subnets --filters \"Name=tag:Name,Values=*private*\" --query 'Subnets[*].{SubnetId:SubnetId,CidrBlock:CidrBlock,AvailabilityZone:AvailabilityZone}' --output table"

echo -e "\n【NAT Gateway確認】"
echo "利用可能なNAT Gateway:"
aws ec2 describe-nat-gateways --query 'NatGateways[?State==`available`].{NatGatewayId:NatGatewayId,SubnetId:SubnetId,PublicIp:NatGatewayAddresses[0].PublicIp}' --output table

echo -e "\n=========================================="
echo "推奨アクション"
echo "=========================================="
echo "1. 停止中インスタンスが不要な場合: Elastic IPを解放"
echo "2. 新しい4つのEC2: プライベートサブネットで起動"
echo "3. RDS: プライベートサブネット（既存設定維持）"
echo "4. S3: VPC Endpoint経由アクセス（設定確認）"