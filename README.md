# sauna-automation
Sauna Studio automation


## Scope

Google Chat Bot、Google Workspace API連携、AIエージェント向けsauna-mcp。

## Architecture

Google Cloud SwiftクライアントとWorkspace APIの対応範囲を区別する。Sauna APIが業務データの正本。zunda-pixel/GoogleChatAppおよびそのProjectは独立しており変更しない。

## Verification

実装言語は対応IssueとADRで確定する。実装後はBot署名・権限・冪等性・Workspace scope・MCP認可のテストを行う。Domain-wide delegationは無断で有効化しない。

初期PRは開発基盤のみを追加します。CIはRepository policy検査を実行し、業務機能の実装や動作検証はまだ含みません。

[AGENTS.md](AGENTS.md) と [CONTRIBUTING.md](CONTRIBUTING.md) に従い、Issueの依存関係を満たしてから独立Review Agentを並行起動して実装します。共通規則適用元: [sauna-studio/.github@075c6695309d](https://github.com/sauna-studio/.github/tree/075c6695309d28baad2dc1391d7d3821b81142cc)。
