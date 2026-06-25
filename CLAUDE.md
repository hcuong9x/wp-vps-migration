# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Detailed rules are split into topic files under [.claude/rules/](.claude/rules/):

| File | Nội dung | `alwaysApply` |
|---|---|---|
| [project-overview.md](.claude/rules/project-overview.md) | Mục đích dự án, vai trò từng script, điều kiện cần | `true` |
| [stacks-and-paths.md](.claude/rules/stacks-and-paths.md) | Docroot paths, vị trí `wp-config.php`, chuẩn hóa tên stack | `true` |
| [configuration.md](.claude/rules/configuration.md) | Biến trong `migrate.env` và ý nghĩa | `false` (globs: `migrate.env*`) |
| [migration-commands.md](.claude/rules/migration-commands.md) | Lệnh chạy migration: single, batch, từng bước thủ công | `false` |
| [bash-conventions.md](.claude/rules/bash-conventions.md) | Shell conventions, stdout protocol, artifact format | `false` (globs: `*.sh`) |
