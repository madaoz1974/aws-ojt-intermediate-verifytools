#!/bin/bash

# セットアップスクリプト
echo "AWS検証環境のセットアップを開始します..."

# スクリプトに実行権限を付与
chmod +x /workspace/scripts/*.sh

# AWS CLIの設定確認
if [ ! -f ~/.aws/credentials ] && [ ! -f ~/.aws/config ]; then
    echo "AWS CLIの設定が必要です。"
    echo "以下のコマンドで設定を行ってください:"
    echo "  aws configure"
fi

# 設定ファイルのテンプレート確認
if [ ! -f /workspace/config/aws-config.sh ]; then
    echo "設定ファイルのテンプレートをコピーして設定してください:"
    echo "  cp /workspace/config/aws-config.template.sh /workspace/config/aws-config.sh"
    echo "  # 設定ファイルを編集してください"
fi

echo "セットアップが完了しました。"
echo ""
echo "使用方法:"
echo "  1. config/aws-config.sh を編集してAWSリソース情報を設定"
echo "  2. ./scripts/verify-aws-resources.sh を実行して検証開始"