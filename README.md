# 纸页文献库

一个面向个人本地 PDF 文献的 macOS 极简管理器。当前版本支持：

- 导入一个或多个 PDF，也支持直接拖入窗口
- 自动复制到本地文献库，不依赖原文件位置
- 按分类整理，支持未分类、重命名、移动和删除分类
- 按标题、文件名、备注搜索
- 内置 PDF 阅读器
- 自动保存最后阅读页
- 编辑标题和阅读备注
- 用文件内容 SHA-256 识别重复 PDF

## 运行

从 GitHub 获取源码后，先按下方步骤构建，再双击生成的 `纸页文献库.app`。首次运行后，文献库默认保存在：

`~/Library/Application Support/ZhiyeLibrary/`

也可以在应用左下角点击“打开文献库文件夹”。

## 从源码重新构建

需要 macOS 13 或更新版本、Xcode Command Line Tools。执行：

```zsh
zsh build.command
```

源码在 `Sources/` 中，使用 SwiftUI、PDFKit、AppKit 和 CryptoKit，无第三方依赖。

## 数据安全

“移除记录”只移除列表中的记录，应用保留文献库里的 PDF 副本；原始 PDF 也不会被删除。导入失败或文献库损坏时，应用会停止写入并提示原因。
