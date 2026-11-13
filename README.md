# sauna-automation
Sauna Studio automation


## Scope

Google Chat Bot、Google Workspace API連携、AIエージェント向けsauna-mcp。

## Architecture

Google Cloud SwiftクライアントとWorkspace APIの対応範囲を区別する。Sauna APIが業務データの正本。zunda-pixel/GoogleChatAppおよびそのProjectは独立しており変更しない。

## Verification

実装言語は対応IssueとADRで確定する。実装後はBot署名・権限・冪等性・Workspace scope・MCP認可のテストを行う。Domain-wide delegationは無断で有効化しない。

Workspace社員確認のローカル検証は Swift 6 / macOS 15以上で `swift build` と `swift test` を実行します。Swift CIはこのライブラリをビルドし、合成データのテストを実行します。Google APIへの接続は別途検証します。

## Workspace社員確認

[ADR-0025](https://github.com/sauna-studio/sauna-docs/blob/main/docs/adr/0025-workspace-authorization.md) に沿い、検証器には紐付け済みの不変なDirectoryユーザーIDと、信頼できる設定から指定した顧客ID・グループIDを渡します。呼び出し元が有効化や施設ロールを決定する際は、別途Sauna APIの認可を適用します。照会は順次実行されるため結果はその確認時点の判断に使い、恒久的な認可として保持しません。`.unavailable` では新規有効化や権限の延長を行わず、確定した非所属と一時障害は区別します。

合成アダプターで停止・アーカイブ・ゲスト・削除・組織外・グループ離脱、照会失敗、有限回再試行を検証します。Directory RESTアダプターは [users.get](https://developers.google.com/workspace/admin/directory/reference/rest/v1/users/get) と [members.hasMember](https://developers.google.com/workspace/admin/directory/reference/rest/v1/members/hasMember) を読み取り専用で呼び出し、判定に必要な項目だけを取得します。OAuthトークンの発行や更新は呼び出し側の責務です。テナント・グループへの実アクセスはWorkspace契約後に検証します。アカウントの紐付けと社員ロールの有効化・失効は後続作業です。

[AGENTS.md](AGENTS.md) と [CONTRIBUTING.md](CONTRIBUTING.md) に従い、Issueの依存関係を満たしてから独立Review Agentを並行起動して実装します。共通規則適用元: [sauna-studio/.github@075c6695309d](https://github.com/sauna-studio/.github/tree/075c6695309d28baad2dc1391d7d3821b81142cc)。
